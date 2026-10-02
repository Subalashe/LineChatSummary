'use strict';

const fs = require('node:fs');
const path = require('node:path');

const Database = require(path.join(__dirname, 'runtime-v13.0.3', 'node_modules', 'better-sqlite3-multiple-ciphers'));
const MAX_MESSAGES = 20000;
const CONTENT_LABELS = new Map([
  [0, ''], [1, '[圖片]'], [2, '[影片]'], [3, '[語音]'], [6, '[位置]'],
  [7, '[貼圖]'], [13, '[聯絡人]'], [14, '[檔案]'], [16, '[連結]']
]);

let activeDb = null;
let activeDbPath = '';
let activeLineVersion = '';
let activeScanStats = { scannedProcessCount: 0, candidateCount: 0, databaseCount: 0, keyAttempts: 0 };
let activeNameDbs = [];
let activeSenderNames = new Map();
let activeNameSources = [];
let initialization = null;

function getLocalAppData() {
  return process.env.LOCALAPPDATA || path.join(process.env.USERPROFILE || '', 'AppData', 'Local');
}

function tableNames(db) {
  return new Set(db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(row => row.name));
}

function getColumns(db, table) {
  try {
    return new Set(db.prepare('PRAGMA table_info("' + table.replace(/"/g, '""') + '")').all().map(row => row.name));
  } catch (_) {
    return new Set();
  }
}

function readColumns(db, table, preferredColumns) {
  const available = getColumns(db, table);
  const selected = preferredColumns.filter(name => available.has(name));
  if (!selected.length) return [];
  const tableName = '"' + table.replace(/"/g, '""') + '"';
  const columnList = selected.map(name => '"' + name.replace(/"/g, '""') + '"').join(', ');
  try { return db.prepare('SELECT ' + columnList + ' FROM ' + tableName).all(); }
  catch (_) { return []; }
}

function firstValue(row, names) {
  for (const name of names) {
    if (row && row[name] !== undefined && row[name] !== null && String(row[name]).trim()) return row[name];
  }
  return '';
}

function asText(value) {
  return value === undefined || value === null ? '' : String(value);
}

const SENDER_ID_COLUMNS = [
  '_mid', 'mid', '_memberMid', 'memberMid', '_groupMemberMid', 'groupMemberMid',
  '_squareMemberMid', 'squareMemberMid', '_userMid', 'userMid', '_senderMid', 'senderMid',
  '_contactMid', 'contactMid', '_profileMid', 'profileMid', '_participantMid', 'participantMid',
  '_senderId', 'senderId', '_memberId', 'memberId', '_userId', 'userId',
  '_contactId', 'contactId', '_profileId', 'profileId', '_participantId', 'participantId', '_id', 'id'
];
const SENDER_NAME_COLUMNS = [
  '_displayName', 'displayName', '_memberName', 'memberName',
  '_userName', 'userName', '_nickname', 'nickname', '_name', 'name', '_displayNameOverridden'
];

function isUsableSenderName(value) {
  if (typeof value !== 'string') return false;
  const text = String(value).trim();
  return Boolean(text) && text.length <= 128 && !/^(?:0|1|true|false|null|undefined)$/i.test(text);
}

function senderColumnCandidates(columns, explicit, kind) {
  const result = explicit.filter(name => columns.has(name));
  for (const name of columns) {
    const normalized = name.replace(/^_+/, '').replace(/_/g, '').toLowerCase();
    if (kind === 'id') {
      if (/^(?:id|mid|sender(?:mid|id)|chatmember(?:mid|id)|chatparticipant(?:mid|id)|groupmember(?:mid|id)|squaremember(?:mid|id)|member(?:mid|id)|participant(?:mid|id)|contact(?:mid|id)|profile(?:mid|id)|user(?:mid|id)|friend(?:mid|id)|peer(?:mid|id))$/.test(normalized)) result.push(name);
    } else if (/(?:displayname|membername|username|contactname|profilename|participantname|nickname|nick|name)$/.test(normalized)) {
      result.push(name);
    }
  }
  return Array.from(new Set(result));
}

function addSenderNames(db, contacts, table, idColumns, nameColumns, overwrite) {
  const tables = tableNames(db);
  if (!tables.has(table)) return null;
  const available = getColumns(db, table);
  const ids = senderColumnCandidates(available, idColumns, 'id');
  const names = senderColumnCandidates(available, nameColumns, 'name');
  if (!ids.length || !names.length) return { table, ids, names, namedRows: 0, indexedNames: 0 };
  let namedRows = 0;
  let indexedNames = 0;
  for (const row of readColumns(db, table, [...ids, ...names])) {
    const keys = Array.from(new Set(ids.map(column => asText(row[column]).trim()).filter(Boolean)));
    const nameValue = names.map(column => row[column]).find(isUsableSenderName);
    const name = asText(nameValue).trim();
    if (!keys.length || !name) continue;
    namedRows++;
    for (const key of keys) {
      if (overwrite || !contacts.has(key) || !contacts.get(key)) {
        contacts.set(key, name);
        indexedNames++;
      }
    }
  }
  return { table, ids, names, namedRows, indexedNames };
}

function profileNameFieldPriority(key) {
  const normalized = String(key || '').replace(/^_+/, '').replace(/[^a-z0-9]/gi, '').toLowerCase();
  if (/^(?:displaynameoverridden|overriddendisplayname|displayname)$/.test(normalized)) return 100;
  if (/^(?:nickname|nick|profilename|contactname|membername|participantname|friendname|targetname)$/.test(normalized)) return 80;
  if (/^(?:name)$/.test(normalized)) return 70;
  if (/(?:displayname|nickname|contactname|membername|participantname|friendname|targetname|profilename)$/.test(normalized)) return 60;
  return 0;
}

function isPlausibleProfileName(value, explicitField) {
  if (typeof value !== 'string') return false;
  const text = value.normalize('NFKC').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!text || text.length > (explicitField ? 128 : 40)) return false;
  if (/^(?:0|1|true|false|null|undefined|unknown|none|n\/a)$/i.test(text)) return false;
  if (/^(?:https?:\/\/|www\.)/i.test(text) || /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i.test(text)) return false;
  if (/^(?:\+?\d[\d ()-]{6,}\d|\d{4}[-/]\d{1,2}[-/]\d{1,2}(?:[ T].*)?)$/.test(text)) return false;
  if (!/[\p{L}\p{N}]/u.test(text)) return false;
  if (!explicitField && /[，。！？!?；;：:\r\n]/.test(text)) return false;
  return true;
}

function extractTargetProfileName(rawValue) {
  let root = rawValue;
  if (Buffer.isBuffer(root)) {
    if (!root.length || root.length > 262144) return '';
    root = root.toString('utf8');
  }
  if (typeof root === 'string') {
    const text = root.trim();
    if (!text || text.length > 262144) return '';
    try { root = JSON.parse(text); }
    catch (_) { return ''; }
  }
  if (!root || typeof root !== 'object') return '';

  const named = [];
  const fallback = [];
  let visited = 0;
  const addCandidate = (target, value, priority) => {
    if (!isPlausibleProfileName(value, priority > 0)) return;
    const name = value.normalize('NFKC').replace(/\s+/g, ' ').trim();
    target.push({ name, priority });
  };
  const visit = (value, depth, inheritedPriority) => {
    if (depth > 12 || ++visited > 5000 || value === null || value === undefined) return;
    if (typeof value === 'string') {
      const text = value.trim();
      if (text.length <= 262144 && /^[\[{\"]/.test(text)) {
        try {
          const nested = JSON.parse(text);
          if (nested && typeof nested === 'object') {
            visit(nested, depth + 1, inheritedPriority);
            return;
          }
        } catch (_) { }
      }
      addCandidate(inheritedPriority > 0 ? named : fallback, value, inheritedPriority);
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) visit(item, depth + 1, inheritedPriority);
      return;
    }
    if (typeof value !== 'object') return;
    for (const [key, child] of Object.entries(value)) {
      const priority = profileNameFieldPriority(key) || inheritedPriority;
      visit(child, depth + 1, priority);
    }
  };
  visit(root, 0, 0);

  const uniqueByName = candidates => {
    const unique = new Map();
    for (const candidate of candidates) {
      const key = candidate.name.toLocaleLowerCase('en-US');
      const current = unique.get(key);
      if (!current || candidate.priority > current.priority) unique.set(key, candidate);
    }
    return Array.from(unique.values());
  };
  const explicitNames = uniqueByName(named).sort((a, b) => b.priority - a.priority);
  if (explicitNames.length) return explicitNames[0].name;
  const fallbackNames = uniqueByName(fallback);
  return fallbackNames.length === 1 ? fallbackNames[0].name : '';
}

function addContactTargetProfileNames(db, contacts) {
  const table = '_contact';
  if (!tableNames(db).has(table)) return null;
  const columns = getColumns(db, table);
  if (!columns.has('_mid') || !columns.has('_targetProfileDetail')) return null;

  let rowsWithProfile = 0;
  let namedRows = 0;
  let indexedNames = 0;
  for (const row of readColumns(db, table, ['_mid', '_targetProfileDetail'])) {
    const mid = asText(row._mid).trim();
    if (!mid || row._targetProfileDetail === null || row._targetProfileDetail === undefined) continue;
    rowsWithProfile++;
    const name = extractTargetProfileName(row._targetProfileDetail);
    if (!name) continue;
    namedRows++;
    // The profile detail belongs to this contact row; link it only through that row's LINE MID.
    if (!contacts.get(mid)) {
      contacts.set(mid, name);
      indexedNames++;
    }
  }
  return {
    table,
    ids: ['_mid'],
    names: ['_targetProfileDetail'],
    namedRows,
    indexedNames,
    profileRows: rowsWithProfile
  };
}

function addNamesFromOtherMemberTables(db, contacts, excludedTables) {
  const sources = [];
  for (const table of tableNames(db)) {
    if (excludedTables.has(table) || !/(contact|profile|member|participant|user|group|room|square|friend|buddy|peer)/i.test(table)) continue;
    const available = getColumns(db, table);
    const ids = senderColumnCandidates(available, SENDER_ID_COLUMNS, 'id');
    const names = senderColumnCandidates(available, SENDER_NAME_COLUMNS, 'name');
    if (!ids.length || !names.length) continue;
    sources.push(addSenderNames(db, contacts, table, ids, names, false));
  }
  return sources.filter(Boolean);
}

function buildSenderNameIndex(databases) {
  const contacts = new Map();
  const sources = [];
  const addSource = (db, databaseIndex, table, ids, names) => {
    const source = addSenderNames(db, contacts, table, ids, names, false);
    if (source) {
      source.databaseIndex = databaseIndex;
      sources.push(source);
    }
  };
  const explicitSources = [
    ['_contact', ['_mid', '_id'], ['_displayNameOverridden', '_displayName', '_name']],
    ['_profile', ['_mid'], ['_displayNameOverridden', '_displayName', '_name', '_nickname']],
    ['_groupMember', ['_memberMid', '_mid', '_groupMemberMid'], ['_displayNameOverridden', '_displayName', '_name', '_nickname']],
    ['_roomMember', ['_memberMid', '_mid', '_roomMemberMid'], ['_displayNameOverridden', '_displayName', '_name', '_nickname']],
    ['_squareMember', ['_squareMemberMid', '_mid'], ['_displayNameOverridden', '_displayName', '_name', '_nickname']]
  ];
  for (const [table, ids, names] of explicitSources) {
    for (let index = 0; index < databases.length; index++) addSource(databases[index], index, table, ids, names);
  }
  for (let index = 0; index < databases.length; index++) {
    const source = addContactTargetProfileNames(databases[index], contacts);
    if (source) {
      source.databaseIndex = index;
      sources.push(source);
    }
  }
  const excludedTables = new Set(explicitSources.map(source => source[0]));
  for (let index = 0; index < databases.length; index++) {
    for (const source of addNamesFromOtherMemberTables(databases[index], contacts, excludedTables)) {
      source.databaseIndex = index;
      sources.push(source);
    }
  }
  return { contacts, sources };
}

function makeChatList(db) {
  const tables = tableNames(db);
  if (!tables.has('_chat') || !tables.has('_message')) {
    throw new Error('LINE 資料庫已解鎖，但找不到預期的聊天資料表；可能是 LINE 已更新，請保留日誌供診斷。');
  }
  const groupNames = new Map();
  const openNames = new Map();
  const roomNames = new Map();

  if (tables.has('_groupChat')) {
    for (const row of readColumns(db, '_groupChat', ['_chatMid', '_chatId', '_mid', '_chatName', '_name', '_displayName'])) {
      const id = asText(firstValue(row, ['_chatMid', '_chatId', '_mid']));
      if (id) groupNames.set(id, asText(firstValue(row, ['_chatName', '_name', '_displayName'])));
    }
  }
  if (tables.has('_squareChat')) {
    for (const row of readColumns(db, '_squareChat', ['_squareChatMid', '_chatMid', '_mid', '_name', '_displayName', '_chatName'])) {
      const id = asText(firstValue(row, ['_squareChatMid', '_chatMid', '_mid']));
      if (id) openNames.set(id, asText(firstValue(row, ['_name', '_displayName', '_chatName'])));
    }
  }
  if (tables.has('_room')) {
    for (const row of readColumns(db, '_room', ['_mid', '_chatMid', '_id', '_name', '_displayName', '_chatName'])) {
      const id = asText(firstValue(row, ['_mid', '_chatMid', '_id']));
      if (id) roomNames.set(id, asText(firstValue(row, ['_name', '_displayName', '_chatName'])));
    }
  }
  const chatColumns = getColumns(db, '_chat');
  if (!chatColumns.has('_id')) throw new Error('LINE 聊天資料表缺少識別欄位；可能是 LINE 版本更新。');
  const rows = readColumns(db, '_chat', ['_id', '_lastUpdatedTime']);
  const seen = new Set();
  let multiIndex = 0;
  const chats = [];
  for (const row of rows) {
    const id = asText(row._id);
    if (!id || seen.has(id)) continue;
    let name = '';
    let type = '';
    if (groupNames.has(id)) { name = groupNames.get(id); type = 'group'; }
    else if (openNames.has(id)) { name = openNames.get(id); type = 'open'; }
    else if (roomNames.has(id)) { name = roomNames.get(id); type = 'multi'; }
    else continue;
    seen.add(id);
    if (!name) {
      if (type === 'multi') name = '多人聊天室 ' + (++multiIndex);
      else name = '未命名群組';
    }
    const updated = Number(row._lastUpdatedTime || 0);
    chats.push({
      id,
      name,
      type,
      typeLabel: type === 'open' ? '社群' : (type === 'multi' ? '多人群組' : '群組'),
      lastMessageAt: updated ? toTaipeiDateTime(updated) : ''
    });
  }
  chats.sort((a, b) => b.lastMessageAt.localeCompare(a.lastMessageAt, 'zh-Hant'));
  return chats;
}

function toTaipeiDateTime(timestamp) {
  let ms = Number(timestamp);
  if (!Number.isFinite(ms) || ms <= 0) return '';
  if (ms < 1000000000000) ms *= 1000;
  else if (ms >= 100000000000000) ms /= 1000;
  try {
    return new Intl.DateTimeFormat('sv-SE', {
      timeZone: 'Asia/Taipei', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23'
    }).format(new Date(ms));
  } catch (_) {
    return new Date(ms).toISOString().replace('T', ' ').replace(/\.\d{3}Z$/, '');
  }
}

function toTaipeiTimestamp(value, isEnd) {
  const input = String(value || '').trim();
  if (!input) throw new Error('日期範圍格式無效，請重新選取。');
  let normalized = input;
  if (/^\d{4}-\d{2}-\d{2}$/.test(input)) {
    normalized += isEnd ? 'T23:59:59.999' : 'T00:00:00';
  } else if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(normalized)) {
    normalized += ':00';
  }
  const withZone = /(?:Z|[+-]\d{2}:?\d{2})$/i.test(normalized) ? normalized : normalized + '+08:00';
  const date = new Date(withZone);
  const timestamp = date.getTime();
  if (!Number.isFinite(timestamp)) throw new Error('日期範圍格式無效，請重新選取。');
  return timestamp;
}

function openEncryptedDatabase(dbPath, keyText, requireMessages) {
  let db = null;
  const keyBytes = Buffer.from(keyText, 'ascii');
  try {
    db = new Database(dbPath, { readonly: true, fileMustExist: true, timeout: 8000 });
    db.pragma("cipher='aes128cbc'");
    db.key(keyBytes);
    db.pragma('query_only = ON');
    const names = tableNames(db);
    if (requireMessages && (!names.has('_chat') || !names.has('_message'))) throw new Error('資料表驗證失敗');
    return db;
  } catch (error) {
    if (db) { try { db.close(); } catch (_) { } }
    throw error;
  } finally {
    keyBytes.fill(0);
  }
}

function newEncryptedConnection(dbPath, keyText) {
  return openEncryptedDatabase(dbPath, keyText, true);
}

async function ensureReady(scanMemory) {
  if (activeDb) return { databasePath: activeDbPath, lineVersion: activeLineVersion, ...activeScanStats };
  if (initialization) return initialization;
  initialization = (async () => {
    let discovery;
    const scanStarted = Date.now();
    let memoryScanMs = 0;
    try {
      discovery = await scanMemory();
      memoryScanMs = Date.now() - scanStarted;
    } catch (error) {
      error.lineDbStats = { memoryScanMs: Date.now() - scanStarted, reusedScanCache: false };
      throw error;
    }
    if (!discovery || !discovery.ok) {
      clearDiscovery(discovery);
      const error = new Error((discovery && discovery.error) || '無法檢查 LINE 本機資料庫。');
      error.lineDbStats = { memoryScanMs, reusedScanCache: false };
      throw error;
    }
    const candidates = Array.isArray(discovery.candidates) ? discovery.candidates : [];
    const candidateCount = candidates.length;
    const candidateLimitReached = Boolean(discovery.candidateLimitReached);
    const paths = Array.isArray(discovery.databasePaths) ? discovery.databasePaths.filter(item => typeof item === 'string') : [];
    if (!paths.length) {
      clearDiscovery(discovery);
      const error = new Error('找不到 LINE 聊天資料庫。請確認 LINE 已登入。');
      error.lineDbStats = { scannedProcessCount: Number(discovery.scannedProcessCount || 0), candidateCount, databaseCount: 0, keyAttempts: 0, memoryScanMs, unlockMs: 0, reusedScanCache: false, candidateLimitReached };
      throw error;
    }
    if (!candidates.length) {
      clearDiscovery(discovery);
      const error = new Error('LINE 記憶體中沒有找到資料庫解鎖候選值。請確認 LINE 已登入，並重新載入群組。');
      error.lineDbStats = { scannedProcessCount: Number(discovery.scannedProcessCount || 0), candidateCount: 0, databaseCount: paths.length, keyAttempts: 0, memoryScanMs, unlockMs: 0, reusedScanCache: false, candidateLimitReached };
      throw error;
    }

    let matched = false;
    let keyAttempts = 0;
    let databaseAttempts = 0;
    let matchedKey = '';
    const unlockStarted = Date.now();
    let unlockMs = 0;
    const existingPaths = paths.filter(dbPath => fs.existsSync(dbPath));
    try {
      databaseAttempts = existingPaths.length;
      // Test each key against the likely database files before moving to the next key.
      // This can stop early when the matching database is not the first file by size.
      for (const candidate of candidates) {
        const keyText = String(candidate && candidate.value || '');
        if (!/^[0-9a-f]{32}$/i.test(keyText)) continue;
        for (const dbPath of existingPaths) {
          keyAttempts++;
          try {
            activeDb = newEncryptedConnection(dbPath, keyText);
            activeDbPath = dbPath;
            activeLineVersion = String(discovery.lineVersion || '');
            matchedKey = keyText;
            matched = true;
            break;
          } catch (_) {
            // Candidate values and database errors are intentionally never logged.
          }
          if (matched) break;
        }
        if (matched) break;
      }
    } finally {
      unlockMs = Date.now() - unlockStarted;
      clearDiscovery(discovery);
    }
    if (!matched) {
      const error = new Error('已掃描 ' + keyAttempts + ' 個候選值及 ' + databaseAttempts + ' 個資料庫檔，但無法解鎖。請保持 LINE 登入後按「重新載入群組」；LINE 更新可能改變加密格式。');
      error.lineDbStats = {
        scannedProcessCount: Number(discovery.scannedProcessCount || 0),
        candidateCount,
        databaseCount: databaseAttempts,
        keyAttempts,
        memoryScanMs,
        unlockMs,
        reusedScanCache: false,
        candidateLimitReached
      };
      throw error;
    }
    activeNameDbs = [activeDb];
    if (matchedKey) {
      for (const dbPath of existingPaths) {
        if (dbPath === activeDbPath) continue;
        try { activeNameDbs.push(openEncryptedDatabase(dbPath, matchedKey, false)); }
        catch (_) { /* Other LINE files may use another key or a different data format. */ }
      }
      matchedKey = '';
    }
    const senderNameIndex = buildSenderNameIndex(activeNameDbs);
    activeSenderNames = senderNameIndex.contacts;
    activeNameSources = senderNameIndex.sources;
    activeScanStats = {
      scannedProcessCount: Number(discovery.scannedProcessCount || 0),
      candidateCount,
      databaseCount: databaseAttempts,
      keyAttempts,
      memoryScanMs,
      unlockMs: Date.now() - unlockStarted,
      reusedScanCache: false,
      candidateLimitReached
    };
    return {
      databasePath: activeDbPath,
      lineVersion: activeLineVersion,
      ...activeScanStats
    };
  })();
  try { return await initialization; }
  finally { initialization = null; }
}

function clearDiscovery(discovery) {
  if (!discovery || !Array.isArray(discovery.candidates)) return;
  for (const candidate of discovery.candidates) {
    if (candidate && typeof candidate.value === 'string') candidate.value = '';
  }
  discovery.candidates = [];
}

function reset() {
  for (const db of activeNameDbs) {
    if (db && db !== activeDb) { try { db.close(); } catch (_) { } }
  }
  if (activeDb) { try { activeDb.close(); } catch (_) { } }
  activeDb = null;
  activeDbPath = '';
  activeLineVersion = '';
  activeNameDbs = [];
  activeSenderNames = new Map();
  activeNameSources = [];
  activeScanStats = { scannedProcessCount: 0, candidateCount: 0, databaseCount: 0, keyAttempts: 0 };
  initialization = null;
}

function listGroups() {
  if (!activeDb) throw new Error('LINE 本機資料尚未載入。');
  return makeChatList(activeDb);
}

function redactCommonData(value) {
  return String(value || '')
    .replace(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi, '[EMAIL]')
    .replace(/(?<!\d)(?:\+?886[- ]?)?09\d{2}[- ]?\d{3}[- ]?\d{3}(?!\d)/g, '[PHONE]');
}

function getMessages(chatId, start, end) {
  if (!activeDb) throw new Error('LINE 本機資料尚未載入。');
  const id = String(chatId || '');
  if (!id) throw new Error('請先選擇 LINE 群組。');
  const fromMs = toTaipeiTimestamp(start, false);
  const untilMs = toTaipeiTimestamp(end, true);
  if (untilMs < fromMs) throw new Error('結束時間必須晚於開始時間。');
  const columns = getColumns(activeDb, '_message');
  for (const required of ['_chatId', '_createdTime', '_text']) {
    if (!columns.has(required)) throw new Error('LINE 訊息資料表缺少必要欄位；可能是 LINE 更新了資料格式。');
  }
  const maxTime = Number(activeDb.prepare('SELECT MAX("_createdTime") AS value FROM _message').get().value || 0);
  const timeScale = maxTime > 0 && maxTime < 1000000000000 ? 0.001 : (maxTime >= 100000000000000 ? 1000 : 1);
  const storedFrom = Math.floor(fromMs * timeScale);
  // The UI sends the millisecond immediately before the exclusive end boundary.
  // Floor is required for second-resolution databases so rounding cannot include the cutoff hour.
  const storedUntil = Math.floor(untilMs * timeScale);
  const count = Number(activeDb.prepare(
    'SELECT COUNT(*) AS count FROM _message WHERE _chatId = ? AND _createdTime >= ? AND _createdTime <= ?'
  ).get(id, storedFrom, storedUntil).count || 0);
  if (!count) return {
    count: 0,
    total: 0,
    text: '',
    senderStats: {
      messages: 0, messagesWithSenderId: 0, selfMessages: 0,
      uniqueSenders: 0, resolvedUniqueSenders: 0, unresolvedUniqueSenders: 0,
      resolvedMessages: 0, unresolvedMessages: 0
    }
  };
  if (count > MAX_MESSAGES) throw new Error('這個日期範圍有 ' + count + ' 則訊息，請縮短時間範圍後再摘要（單次上限 ' + MAX_MESSAGES + ' 則）。');

  const messageFields = ['_createdTime', '_from', '_text'];
  if (columns.has('_contentType')) messageFields.push('_contentType');
  const messageFieldSql = messageFields.map(name => '"' + name + '"').join(', ');
  const rows = activeDb.prepare(
    'SELECT ' + messageFieldSql + ' FROM _message WHERE _chatId = ? AND _createdTime >= ? AND _createdTime <= ? ORDER BY _createdTime ASC LIMIT ?'
  ).all(id, storedFrom, storedUntil, MAX_MESSAGES);
  const lines = [];
  const senderIds = new Set();
  const resolvedSenderIds = new Set();
  const unresolvedSenderIds = new Set();
  let selfMessages = 0;
  let resolvedMessages = 0;
  let unresolvedMessages = 0;
  for (const row of rows) {
    const time = toTaipeiDateTime(row._createdTime);
    const senderId = asText(row._from);
    let sender;
    if (senderId) {
      senderIds.add(senderId);
      sender = activeSenderNames.get(senderId) || '';
      if (sender) {
        resolvedSenderIds.add(senderId);
        resolvedMessages++;
      } else {
        unresolvedSenderIds.add(senderId);
        unresolvedMessages++;
        let aliasIndex = Array.from(unresolvedSenderIds).indexOf(senderId);
        let alias = '';
        do {
          alias = String.fromCharCode(65 + (aliasIndex % 26));
          aliasIndex = Math.floor(aliasIndex / 26) - 1;
        } while (aliasIndex >= 0);
        sender = '未對應姓名 ' + alias;
      }
    } else {
      selfMessages++;
      sender = '我';
    }
    const contentType = Number(row._contentType || 0);
    const label = CONTENT_LABELS.get(contentType);
    const rawText = asText(row._text);
    const body = rawText.trim() || label || '[非文字訊息]';
    const safeSender = redactCommonData(sender).replace(/[\r\n]+/g, ' ');
    const safeBody = redactCommonData(body).replace(/[\r\n]+/g, ' ');
    lines.push('[' + time + '] 發言者：' + safeSender + '｜訊息：' + safeBody);
  }
  return {
    count: rows.length,
    total: count,
    text: lines.join('\n'),
    senderStats: {
      messages: rows.length,
      messagesWithSenderId: rows.length - selfMessages,
      selfMessages,
      uniqueSenders: senderIds.size,
      resolvedUniqueSenders: resolvedSenderIds.size,
      unresolvedUniqueSenders: unresolvedSenderIds.size,
      resolvedMessages,
      unresolvedMessages,
      nameDatabaseCount: activeNameDbs.length,
      nameSources: activeNameSources
    }
  };
}

module.exports = { ensureReady, reset, listGroups, getMessages };
