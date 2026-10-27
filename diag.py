import json, time, urllib.request, urllib.error

APP_UA = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36 FunRun'

def get(url, data=None, ctype=None):
    h = {'User-Agent': APP_UA}
    if ctype: h['Content-Type'] = ctype
    req = urllib.request.Request(url, data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read(3000000).decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')
    except Exception as e:
        return 0, str(e)

def links(s):
    out, k = [], 0
    while True:
        k = s.find('href="', k)
        if k < 0: break
        e = s.find('"', k + 6)
        out.append(s[k + 6:e]); k = e
    return out

for u in ('https://trackleaders.com/history', 'https://trackleaders.com/features', 'https://trackleaders.com/?past=1'):
    st, s = get(u)
    print(u, st, len(s))
    print('  links', len(links(s)), links(s)[:400])
    i = s.find('<body')
    print('  body', s[i:i + 3000].replace('\n', ' '))
for u in ('https://api2.madcap.cc/events', 'https://api2.madcap.cc/event/list', 'https://api2.madcap.cc/events/v6', 'https://api2.madcap.cc/event'):
    st, s = get(u)
    print(u, st, s[:500].replace('\n', ' '))
