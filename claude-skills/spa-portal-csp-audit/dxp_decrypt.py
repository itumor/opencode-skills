"""Decrypt an EIS portal /dxp.json (CryptoJS AES, key literal in main.js) and print host/URL fields only.
Usage: python3 -I dxp_decrypt.py <dir> <host>...   (expects <dir>/<host>.dxp.json and <dir>/<host>.js/main.js)
The key and secret-like fields are never printed.
"""
import json, os, re, subprocess, sys, tempfile

KEY_RE = r'"([0-9a-z]{8}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{12})"'
SECRETISH = r'(?i)secret|password|token|key|credential'

def find_key(main_js):
    i = main_js.find('function resolveDxpDecryptionSecret')
    m = re.search(KEY_RE, main_js[i:i + 2000]) if i >= 0 else None
    return m.group(1) if m else None

def fields(o, p=''):
    if isinstance(o, dict):
        for k, v in o.items(): yield from fields(v, p + '.' + k)
    elif isinstance(o, list):
        for n, v in enumerate(o): yield from fields(v, f'{p}[{n}]')
    elif re.search(SECRETISH, p):
        yield p, '<redacted>'
    elif isinstance(o, str) and ('://' in o or re.search(r'(?i)host|path|url|domain|origin', p)):
        yield p, o

def main(base, hosts):
    for h in hosts:
        key = find_key(open(os.path.join(base, h + '.js', 'main.js'), encoding='utf-8', errors='replace').read())
        if not key:
            print('===', h, 'key not found (server mode? cookie dxpHashSecret)'); continue
        with tempfile.NamedTemporaryFile('w', delete=False) as k:
            k.write(key)
        try:
            out = subprocess.run(['openssl', 'enc', '-d', '-aes-256-cbc', '-md', 'md5', '-a', '-A', '-pass', 'file:' + k.name,
                                  '-in', os.path.join(base, h + '.dxp.json')], capture_output=True)
        finally:
            os.unlink(k.name)
        print('===', h, 'rc', out.returncode)
        try:
            for p, v in fields(json.loads(out.stdout)): print(f'  {p} = {v}')
        except ValueError:
            print('  not json')

def selftest():
    assert find_key('function resolveDxpDecryptionSecret(e){x="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}') == 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    got = dict(fields({'externalHost': 'a.test', 'sso': {'clientSecret': 's', 'metadataUrl': 'https://k.test/x'}, 'n': 1}))
    assert got == {'.externalHost': 'a.test', '.sso.clientSecret': '<redacted>', '.sso.metadataUrl': 'https://k.test/x'}
    print('selftest ok')

if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        selftest()
    else:
        main(sys.argv[1], sys.argv[2:])
