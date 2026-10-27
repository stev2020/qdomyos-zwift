import json, time, urllib.request, urllib.error, concurrent.futures as cf

APP_UA = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36 FunRun'
KEEP = ('server', 'x-vercel-mitigated', 'x-vercel-cache', 'retry-after', 'cache-control', 'x-vercel-id', 'content-type')

def get(url, ua=APP_UA):
    req = urllib.request.Request(url, headers={'User-Agent': ua})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read(), time.time() - t
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read(), time.time() - t
    except Exception as e:
        return 0, {}, str(e).encode(), time.time() - t

def show(tag, res):
    st, h, b, dt = res
    keep = {k.lower(): v for k, v in h.items() if k.lower() in KEEP}
    s = b[:30000].decode('utf-8', 'replace')
    i = s.find('<title>')
    title = s[i + 7:s.find('</title>', i)] if i >= 0 else ''
    print(f'{time.strftime("%H:%M:%S")} {tag}: {st} {dt:.2f}s {len(b)}B {keep} {title!r}', flush=True)
    return st

print('--- user agents')
for ua in (APP_UA, 'QZ FunRun (github.com/cagnulein/qdomyos-zwift)', 'curl/7.81.0'):
    show('races ua=' + ua[:30], get('https://dotwatcher.cc/races', ua))
    time.sleep(2)

r = get('https://dotwatcher.cc/races')
show('races', r)
html = r[2].decode('utf-8', 'replace')
k = html.find('id="__NEXT_DATA__"')
if k < 0:
    print('no __NEXT_DATA__ in the races page; body start:', html[:1500].replace('\n', ' '))
    raise SystemExit(0)
a = html.find('>', k) + 1
nd = json.loads(html[a:html.find('</script>', a)])
build = nd['buildId']
d = nd['props']['pageProps']['data']
slugs = []
for key in ('liveRacesCollection', 'upcomingRaceCollection', 'pastRacesCollection'):
    for x in ((d.get(key) or {}).get('items') or []):
        if x and x.get('slug'):
            slugs.append(x['slug'])
print('build', build, 'races', len(slugs))
show('archive', get(f'https://dotwatcher.cc/_next/data/{build}/results.json'))

print('--- race pages two at a time (as the app list check did)')
def race(s):
    return s, get(f'https://dotwatcher.cc/_next/data/{build}/race/{s}.json?slug={s}')
codes = []
with cf.ThreadPoolExecutor(2) as ex:
    for s, res in ex.map(race, slugs[:45]):
        codes.append(show('race ' + s, res))
print('codes', codes)
show('archive again', get(f'https://dotwatcher.cc/_next/data/{build}/results.json'))
show('races again', get('https://dotwatcher.cc/races'))
for wait in (30, 60):
    time.sleep(wait)
    show(f'archive after +{wait}s', get(f'https://dotwatcher.cc/_next/data/{build}/results.json'))
