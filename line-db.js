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

function newEncryptedConnection(dbPath, keyText) {
  let db = null;
  const keyBytes = Buffer.from(keyText, 'ascii');
  try {
    db = new Database(dbPath, { readonly: true, fileMustExist: true, timeout: 8000 });
    db.pragma("cipher='aes128cbc'");
    db.key(keyBytes);
    db.pragma('query_only = ON');
    const names = tableNames(db);
    if (!names.has('_chat') || !names.has('_message')) throw new Error('資料表驗證失敗');
    return db;
  } catch (error) {
    if (db) { try { db.close(); } catch (_) { } }
    throw error;
  } finally {
    keyBytes.fill(0);
  }
}

async function ensureReady(scanMemory) {
  if (activeDb) return { databasePath: activeDbPath, lineVersion: activeLineVersion, ...activeScanStats };
  if (initialization) return initialization;
  initialization = (async () => {
    const discovery = await scanMemory();
    if (!discovery || !discovery.ok) throw new Error((discovery && discovery.error) || '無法檢查 LINE 本機資料庫。');
    const candidates = Array.isArray(discovery.candidates) ? discovery.candidates : [];
    const paths = Array.isArray(discovery.databasePaths) ? discovery.databasePaths.filter(item => typeof item === 'string') : [];
    if (!paths.length) throw new Error('找不到 LINE 聊天資料庫。請確認 LINE 已登入。');
    if (!candidates.length) throw new Error('LINE 記憶體中沒有找到資料庫解鎖候選值。請確認 LINE 已登入，並重新載入群組。');

    let matched = false;
    let keyAttempts = 0;
    let databaseAttempts = 0;
    try {
      for (const dbPath of paths) {
        if (!fs.existsSync(dbPath)) continue;
        databaseAttempts++;
        for (const candidate of candidates) {
          const keyText = String(candidate && candidate.value || '');
          if (!/^[0-9a-f]{32}$/i.test(keyText)) continue;
          keyAttempts++;
          try {
            activeDb = newEncryptedConnection(dbPath, keyText);
            activeDbPath = dbPath;
            activeLineVersion = String(discovery.lineVersion || '');
            matched = true;
            break;
          } catch (_) {
            // Candidate values and database errors are intentionally never logged.
          }
        }
        if (matched) break;
      }
    } finally {
      for (const candidate of candidates) {
        if (candidate && typeof candidate.value === 'string') candidate.value = '';
      }
      discovery.candidates = [];
    }
    if (!matched) throw new Error('已掃描 ' + keyAttempts + ' 個候選值及 ' + databaseAttempts + ' 個資料庫檔，但無法解鎖。請保持 LINE 登入後按「重新載入群組」；LINE 更新可能改變加密格式。');
    activeScanStats = {
      scannedProcessCount: Number(discovery.scannedProcessCount || 0),
      candidateCount: candidates.length,
      databaseCount: databaseAttempts,
      keyAttempts
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

function reset() {
  if (activeDb) { try { activeDb.close(); } catch (_) { } }
  activeDb = null;
  activeDbPath = '';
  activeLineVersion = '';
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
  const storedUntil = Math.ceil(untilMs * timeScale);
  const count = Number(activeDb.prepare(
    'SELECT COUNT(*) AS count FROM _message WHERE _chatId = ? AND _createdTime >= ? AND _createdTime <= ?'
  ).get(id, storedFrom, storedUntil).count || 0);
  if (!count) return { count: 0, total: 0, text: '' };
  if (count > MAX_MESSAGES) throw new Error('這個日期範圍有 ' + count + ' 則訊息，請縮短時間範圍後再摘要（單次上限 ' + MAX_MESSAGES + ' 則）。');

  const messageFields = ['_createdTime', '_from', '_text'];
  if (columns.has('_contentType')) messageFields.push('_contentType');
  const messageFieldSql = messageFields.map(name => '"' + name + '"').join(', ');
  const rows = activeDb.prepare(
    'SELECT ' + messageFieldSql + ' FROM _message WHERE _chatId = ? AND _createdTime >= ? AND _createdTime <= ? ORDER BY _createdTime ASC LIMIT ?'
  ).all(id, storedFrom, storedUntil, MAX_MESSAGES);
  const contacts = new Map();
  const tables = tableNames(activeDb);
  if (tables.has('_contact')) {
    for (const row of readColumns(activeDb, '_contact', ['_mid', '_id', '_displayNameOverridden', '_displayName', '_name'])) {
      const key = asText(firstValue(row, ['_mid', '_id']));
      if (key) contacts.set(key, asText(firstValue(row, ['_displayNameOverridden', '_displayName', '_name'])));
    }
  }
  if (tables.has('_squareMember')) {
    for (const row of readColumns(activeDb, '_squareMember', ['_squareMemberMid', '_mid', '_displayName', '_name'])) {
      const key = asText(firstValue(row, ['_squareMemberMid', '_mid']));
      if (key && !contacts.has(key)) contacts.set(key, asText(firstValue(row, ['_displayName', '_name'])));
    }
  }
  const lines = [];
  for (const row of rows) {
    const time = toTaipeiDateTime(row._createdTime);
    const senderId = asText(row._from);
    const sender = senderId ? (contacts.get(senderId) || '群組成員') : '我';
    const contentType = Number(row._contentType || 0);
    const label = CONTENT_LABELS.get(contentType);
    const rawText = asText(row._text);
    const body = rawText.trim() || label || '[非文字訊息]';
    lines.push('[' + time + '] ' + redactCommonData(sender) + ': ' + redactCommonData(body));
  }
  return { count: rows.length, total: count, text: lines.join('\n') };
}

module.exports = { ensureReady, reset, listGroups, getMessages };
