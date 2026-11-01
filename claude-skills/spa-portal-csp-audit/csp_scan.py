"""Scan a downloaded SPA bundle for what each CSP directive must allow.
Usage: python3 -I csp_scan.py <dir> <host>...   (expects <dir>/<host>.js/*.js|*.css)
"""
import glob, os, re, sys

AUTH_IFRAME = ['checkLoginIframe', 'silent-check-sso', 'silentCheckSso', 'login-status-iframe', '3p-cookies',
               'signinSilent', 'automaticSilentRenew', 'monitorSession', 'check_session_iframe', 'IFrameWindow']
PATS = {
    'createObjectURL (img/connect blob:)': r'createObjectURL',
    'new Function / eval (unsafe-eval)': r'new Function\(|\beval\(',
    'script loaders (script-src)': r'maps\.googleapis\.com|cdn\.jsdelivr|unpkg\.com|cdnjs',
    'WebSocket (connect-src wss:)': r'new WebSocket|wss://',
    'Worker (worker-src)': r'new Worker\(',
    'map tiles (img-src)': r'tile\.openstreetmap|\{s\}\.tile|arcgisonline|mapbox',
}

def read(paths):
    return ''.join(open(p, encoding='utf-8', errors='replace').read() for p in paths)

def main(base, hosts):
    for h in hosts:
        d = os.path.join(base, h + '.js')
        js, css = read(glob.glob(d + '/*.js')), read(glob.glob(d + '/*.css'))
        print('===', h, f'{len(js)}B js, {len(css)}B css')
        for name, p in PATS.items():
            print(f'  {name:38} {len(re.findall(p, js))}')
        print('  auth iframe markers (0 = no frame-src):', {m: js.count(m) for m in AUTH_IFRAME if js.count(m)} or 0)
        print('  oidc token XHR:', js.count('grant_type=authorization_code'))
        print('  ext https hosts in JS:', sorted(set(re.findall(r'https://[a-z0-9.-]+\.[a-z]{2,}\b', js)))[:30])
        print('  css url() hosts (font/img-src):', sorted(set(re.findall(r'url\(["\']?https?://([^/)"\']+)', css))))

def selftest():
    import tempfile
    t = tempfile.mkdtemp(); d = os.path.join(t, 'x.test.js'); os.mkdir(d)
    open(d + '/a.js', 'w').write('URL.createObjectURL(b);fetch("https://api.x.test/v");grant_type=authorization_code')
    open(d + '/a.css', 'w').write('@font-face{src:url(https://fonts.gstatic.com/a.woff2)}')
    js = read([d + '/a.js']); css = read([d + '/a.css'])
    assert len(re.findall(PATS['createObjectURL (img/connect blob:)'], js)) == 1
    assert re.findall(r'url\(["\']?https?://([^/)"\']+)', css) == ['fonts.gstatic.com']
    assert not any(js.count(m) for m in AUTH_IFRAME)
    print('selftest ok')

if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        selftest()
    else:
        main(sys.argv[1], sys.argv[2:])
