import json, time, urllib.request, urllib.error, html as H

APP_UA = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36 FunRun'

def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': APP_UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read(5000000).decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')
    except Exception as e:
        return 0, str(e)

st, robots = get('https://trackleaders.com/robots.txt')
print('robots', st, robots[:600].replace('\n', ' | '))
for page in ('https://trackleaders.com/history', 'https://trackleaders.com/'):
    st, s = get(page)
    print('PAGE', page, st, len(s))
    # each event: <a title="...<h3>TITLE</h3> DESC<br><br><b>Start:</b> DATE" href=//trackleaders.com/ID>
    k = 0
    n = 0
    sec = ''
    while True:
        a = s.find('<a title="', k)
        if a < 0: break
        # section heading before this link
        h = s.rfind('<h4>', 0, a); h3 = s.rfind('<h3>Currently', 0, a)
        t_end = s.find('"', a + 10)
        title_attr = s[a + 10:t_end]
        href_k = s.find('href=', t_end)
        href_e = min([x for x in (s.find('>', href_k), s.find(' ', href_k)) if x > 0])
        href = s[href_k + 5:href_e].strip('"\'')
        k = href_e
        t = H.unescape(title_attr)
        h3a = t.find('<h3>'); h3b = t.find('</h3>')
        name = t[h3a + 4:h3b] if h3a >= 0 else ''
        rest = t[h3b + 5:] if h3b >= 0 else t
        start = ''
        si = rest.find('Start:</b>')
        if si >= 0: start = rest[si + 10:].strip()
        desc = rest.split('<br>')[0].strip()
        hs = s[h:s.find('</h4>', h)] if h >= 0 else ''
        print(f'{href} | {name} | {start} | {desc[:110]} | {hs[4:60]}')
        n += 1
    print('events', n)
