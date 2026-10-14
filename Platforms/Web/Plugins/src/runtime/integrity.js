export async function digest(bytes) {
  const value = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(value), byte => byte.toString(16).padStart(2, '0')).join('');
}
export async function fetchBytes(url, maximum = 128 * 1024 * 1024) {
  const response = await fetch(url, { credentials: 'same-origin', redirect: 'error' });
  if (!response.ok) throw Error(`Could not load plugin: ${response.status}`);
  const reader = response.body.getReader(); const chunks = []; let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      length += value.byteLength;
      if (length > maximum) throw Error('Plugin file exceeds size limit');
      chunks.push(value);
    }
  } finally { await reader.cancel(); }
  const result = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}
