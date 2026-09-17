'use strict';
const crypto = require('crypto');

function publicUrl(value) {
  try {
    const url = new URL(String(value));
    if (!['http:', 'https:'].includes(url.protocol)) return '';
    url.username = ''; url.password = ''; url.search = ''; url.hash = '';
    return url.toString();
  } catch (_) { return ''; }
}

function redact(value) {
  return String(value == null ? '' : value)
    .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, '[redacted private key]')
    .replace(/https?:\/\/[^\s<>"')]+/gi, url => publicUrl(url) || '[redacted URL]')
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, 'Bearer [redacted]')
    .replace(/\bsk-[A-Za-z0-9_-]{12,}/g, '[redacted key]')
    .replace(/((?:["']?)(?:access_token|token|password|secret|api[_-]?key|authorization|cookie)(?:["']?)\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}]+)/gi, '$1[redacted]')
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '')
    .slice(0, 65536);
}

function createAuthorization({ token, port, host = '127.0.0.1' }) {
  function sameOrigin(req) {
    return req.headers.host === host + ':' + port() &&
      (!req.headers.origin || req.headers.origin === 'http://' + host + ':' + port());
  }
  function matches(candidate) {
    if (typeof candidate !== 'string') return false;
    const a = Buffer.from(candidate);
    const b = Buffer.from(token);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }
  const cookieName = () => 'dshdeck_' + port();
  function authenticated(req) {
    if (!sameOrigin(req)) return false;
    const header = req.headers.authorization || '';
    if (header.startsWith('Bearer ') && matches(header.slice(7))) return true;
    for (const part of String(req.headers.cookie || '').split(';')) {
      const split = part.trim().indexOf('=');
      if (split < 0) continue;
      const field = part.trim();
      if (field.slice(0, split) === cookieName() && matches(field.slice(split + 1))) return true;
    }
    return false;
  }
  function sessionCookie() { return cookieName() + '=' + token + '; HttpOnly; SameSite=Strict; Path=/'; }
  return { sameOrigin, authenticated, sessionCookie };
}

const securityHeaders = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
};

module.exports = { publicUrl, redact, createAuthorization, securityHeaders };
