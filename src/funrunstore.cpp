#include "funrunstore.h"
#include "homeform.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QSaveFile>
#include <QXmlStreamReader>
#include <QtMath>

#include <algorithm>
#include <cmath>

namespace {

const double EARTH_RADIUS = 6371008.8;

double round1(double v) { return std::round(v * 10.0) / 10.0; }

// heart rate zone as at Orangetheory, by share of the maximum heart rate: grey, blue, green, orange, red
int heartRateZone(double percent) {
    if (percent < 61)
        return 0;
    if (percent < 71)
        return 1;
    if (percent < 84)
        return 2;
    if (percent < 92)
        return 3;
    return 4;
}

QJsonObject readJsonFile(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return QJsonObject();
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    return doc.isObject() ? doc.object() : QJsonObject();
}

bool writeJsonFile(const QString &path, const QJsonObject &obj) {
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.write(QJsonDocument(obj).toJson(QJsonDocument::Compact));
    return f.commit();
}

} // namespace

// ------------------------------------------------------------------ route

bool FunRunRoute::load(const QString &gpxFile) {
    routeName.clear();
    routeFile = gpxFile;
    x.clear();
    y.clear();
    s.clear();
    e.clear();
    QFile f(gpxFile);
    if (gpxFile.isEmpty() || !f.open(QIODevice::ReadOnly))
        return false;
    QXmlStreamReader xml(&f);
    QVector<double> lat, lon, ele;
    bool inPoint = false;    // inside a track or route point
    bool inWaypoint = false; // inside a waypoint: its name is not the name of the route
    bool inMetadata = false, inTrack = false;
    QString metaName, trackName;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            const QStringRef n = xml.name();
            if (n == QLatin1String("trkpt") || n == QLatin1String("rtept")) {
                lat.append(xml.attributes().value(QLatin1String("lat")).toDouble());
                lon.append(xml.attributes().value(QLatin1String("lon")).toDouble());
                ele.append(qQNaN());
                inPoint = true;
            } else if (n == QLatin1String("wpt")) {
                inWaypoint = true;
            } else if (n == QLatin1String("metadata")) {
                inMetadata = true;
            } else if (n == QLatin1String("trk") || n == QLatin1String("rte")) {
                inTrack = true;
            } else if (n == QLatin1String("ele") && inPoint) {
                bool ok = false;
                const double v = xml.readElementText().toDouble(&ok);
                if (ok)
                    ele.last() = v;
            } else if (n == QLatin1String("name") && !inPoint && !inWaypoint) {
                const QString name = xml.readElementText().trimmed();
                if (inTrack && trackName.isEmpty())
                    trackName = name;
                else if (inMetadata && metaName.isEmpty())
                    metaName = name;
            }
        } else if (xml.isEndElement()) {
            const QStringRef n = xml.name();
            if (n == QLatin1String("trkpt") || n == QLatin1String("rtept"))
                inPoint = false;
            else if (n == QLatin1String("wpt"))
                inWaypoint = false;
            else if (n == QLatin1String("metadata"))
                inMetadata = false;
            else if (n == QLatin1String("trk") || n == QLatin1String("rte"))
                inTrack = false;
        }
    }
    // the name of the track first (route tools put their own name into the metadata), then the metadata, the file
    if (trackName.endsWith(QLatin1String(".gpx"), Qt::CaseInsensitive))
        trackName.chop(4);
    routeName = !trackName.isEmpty() ? trackName : !metaName.isEmpty() ? metaName : QFileInfo(gpxFile).completeBaseName();
    if (lat.size() < 2)
        return false;

    // points without elevation take the one of the nearest point before them (or the first one known)
    double known = 0;
    for (double v : qAsConst(ele)) {
        if (!qIsNaN(v)) {
            known = v;
            break;
        }
    }
    lat0 = lat.first();
    lon0 = lon.first();
    ky = EARTH_RADIUS * M_PI / 180.0;
    kx = cos(qDegreesToRadians(lat0)) * ky;
    for (int i = 0; i < lat.size(); i++) {
        if (!qIsNaN(ele[i]))
            known = ele[i];
        const double px = (lon[i] - lon0) * kx, py = (lat[i] - lat0) * ky;
        if (!s.isEmpty()) {
            const double step = std::hypot(px - x.last(), py - y.last());
            if (step < 0.3)
                continue;
            s.append(s.last() + step);
        } else {
            s.append(0);
        }
        x.append(px);
        y.append(py);
        e.append(known);
    }
    return valid();
}

int FunRunRoute::segment(double d) const {
    int lo = 0, hi = s.size() - 1;
    if (d <= 0)
        return 0;
    if (d >= s[hi])
        return hi - 1;
    while (hi - lo > 1) {
        const int mid = (lo + hi) / 2;
        if (s[mid] <= d)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}

double FunRunRoute::elevationAt(double d) const {
    if (!valid())
        return 0;
    const int i = segment(d);
    const double len = s[i + 1] - s[i];
    const double u = len > 0 ? qBound(0.0, (d - s[i]) / len, 1.0) : 0.0;
    return e[i] + (e[i + 1] - e[i]) * u;
}

QJsonObject FunRunRoute::describe() const {
    QJsonObject o;
    o[QStringLiteral("name")] = routeName;
    if (!valid())
        return o;
    const double len = length();
    // climbing: elevation every 20 m, averaged over 100 m (GPX elevations are noisy)
    const int n = qMax(2, (int)(len / 20.0) + 1);
    QVector<double> ev(n);
    for (int i = 0; i < n; i++)
        ev[i] = elevationAt(len * i / (n - 1));
    double ascent = 0, lo = 1e9, hi = -1e9, prev = 0;
    for (int i = 0; i < n; i++) {
        double sum = 0;
        int cnt = 0;
        for (int k = qMax(0, i - 2); k <= qMin(n - 1, i + 2); k++) {
            sum += ev[k];
            cnt++;
        }
        const double v = sum / cnt;
        if (i && v > prev)
            ascent += v - prev;
        prev = v;
        lo = qMin(lo, ev[i]);
        hi = qMax(hi, ev[i]);
    }
    // outline in a square 0..1 (north up), 48 points along the route
    double minX = 1e18, maxX = -1e18, minY = 1e18, maxY = -1e18;
    for (int i = 0; i < x.size(); i++) {
        minX = qMin(minX, x[i]);
        maxX = qMax(maxX, x[i]);
        minY = qMin(minY, y[i]);
        maxY = qMax(maxY, y[i]);
    }
    const double span = qMax(1.0, qMax(maxX - minX, maxY - minY));
    const double offX = (span - (maxX - minX)) / 2, offY = (span - (maxY - minY)) / 2;
    QJsonArray shape, profile;
    for (int k = 0; k < 48; k++) {
        const double d = len * k / 47;
        const int i = segment(d);
        const double segLen = s[i + 1] - s[i];
        const double u = segLen > 0 ? qBound(0.0, (d - s[i]) / segLen, 1.0) : 0.0;
        const double px = x[i] + (x[i + 1] - x[i]) * u, py = y[i] + (y[i + 1] - y[i]) * u;
        shape.append(QJsonArray{std::round((px - minX + offX) / span * 1000) / 1000,
                                std::round((1.0 - (py - minY + offY) / span) * 1000) / 1000});
    }
    for (int k = 0; k < 60; k++)
        profile.append((qint64)std::lround(elevationAt(len * k / 59)));
    o[QStringLiteral("length")] = (qint64)std::lround(len);
    o[QStringLiteral("ascent")] = (qint64)std::lround(ascent);
    o[QStringLiteral("eleMin")] = (qint64)std::lround(lo);
    o[QStringLiteral("eleMax")] = (qint64)std::lround(hi);
    o[QStringLiteral("shape")] = shape;
    o[QStringLiteral("profile")] = profile;
    return o;
}

double FunRunRoute::project(double lat, double lon, double hint, double &off) const {
    off = 1e9;
    if (!valid())
        return 0;
    const double px = (lon - lon0) * kx, py = (lat - lat0) * ky;
    double best = 1e18, bestS = 0;
    auto scan = [&](int i0, int i1) {
        for (int i = i0; i < i1; i++) {
            const double ax = x[i] - px, ay = y[i] - py;
            const double dx = x[i + 1] - x[i], dy = y[i + 1] - y[i], l2 = dx * dx + dy * dy;
            const double t = l2 > 0 ? qBound(0.0, -(ax * dx + ay * dy) / l2, 1.0) : 0.0;
            const double qx = ax + t * dx, qy = ay + t * dy, d2 = qx * qx + qy * qy;
            if (d2 < best) {
                best = d2;
                bestS = s[i] + t * (s[i + 1] - s[i]);
            }
        }
    };
    const int last = s.size() - 1;
    if (hint >= 0) {
        // near the last position first: the route may pass the same place twice (hairpins, laps)
        scan(qMax(0, segment(hint - 800)), qMin(last, segment(hint + 800) + 1));
        if (best <= 80.0 * 80.0) {
            off = std::sqrt(best);
            return bestS;
        }
        best = 1e18;
    }
    scan(0, last);
    off = std::sqrt(best);
    return bestS;
}

// ------------------------------------------------------------------ store

QString FunRunStore::folder() { return homeform::getWritableAppDir() + QStringLiteral("funrun/"); }

QString FunRunStore::routeKey(const QString &gpxFile) {
    return gpxFile.isEmpty() ? QString() : QFileInfo(gpxFile).completeBaseName().toLower();
}

bool FunRunStore::validId(const QString &id) {
    if (id.isEmpty() || id.size() > 40)
        return false;
    for (const QChar c : id) {
        if (!c.isDigit() && c != QLatin1Char('-'))
            return false;
    }
    return true;
}

void FunRunStore::writeIndex(const QJsonArray &rides) {
    QJsonObject index;
    index[QStringLiteral("v")] = 1;
    index[QStringLiteral("rides")] = rides;
    if (!writeJsonFile(folder() + QStringLiteral("rides.json"), index))
        qDebug() << QStringLiteral("FunRun: could not write the ride index");
}

QString FunRunStore::saveRide(const QList<SessionLine> &session, const QHash<quint32, float> &windPercent,
                              const RideInfo &info) {
    const int n = session.size();
    if (n < 60 || session.last().distance < 0.1) {
        qDebug() << QStringLiteral("FunRun: ride too short to keep") << n;
        return QString();
    }

    // distance along the route for every sample (-1: not on the route, e.g. before the route was loaded)
    FunRunRoute route;
    const bool hasRoute = route.load(info.gpxFile);
    QVector<double> rd(n, -1.0);
    if (hasRoute) {
        double hint = -1;
        for (int i = 0; i < n; i++) {
            const QGeoCoordinate &c = session.at(i).coordinate;
            if (!c.isValid() || (c.latitude() == 0 && c.longitude() == 0))
                continue;
            double off = 0;
            const double d = route.project(c.latitude(), c.longitude(), hint, off);
            if (off > 80)
                continue;
            rd[i] = d;
            hint = d;
        }
    }
    int routeStart = -1, routeEnd = -1;
    double reached = -1;
    for (int i = 0; i < n; i++) {
        if (rd[i] < 0)
            continue;
        if (routeStart < 0)
            routeStart = i;
        if (rd[i] > reached) {
            reached = rd[i];
            routeEnd = i;
        }
    }
    const bool onRoute = routeStart >= 0;

    // totals and averages (averages over the samples in motion)
    double sumSpeed = 0, maxSpeed = 0, sumPower = 0, sumCadence = 0, sumLevel = 0, joules = 0;
    double sumHeart = 0, maxHeart = 0, maxPower = 0;
    int moving = 0, withHeart = 0;
    double zones[5] = {0, 0, 0, 0, 0};
    double windSum = 0;
    int windSamples = 0, windHead = 0, windSide = 0, windTail = 0;
    const double hrMax = info.hrMax > 0 ? info.hrMax : 190;
    for (int i = 0; i < n; i++) {
        const SessionLine &l = session.at(i);
        joules += l.watt;
        maxSpeed = qMax(maxSpeed, l.speed);
        maxPower = qMax(maxPower, (double)l.watt);
        if (l.speed > 0.5 || l.cadence > 0) {
            moving++;
            sumSpeed += l.speed;
            sumPower += l.watt;
            sumCadence += l.cadence;
            sumLevel += l.resistance;
            if (info.windStrength > 0) {
                const auto w = windPercent.constFind(l.elapsedTime);
                if (w != windPercent.constEnd() && *w >= 0) {
                    windSum += *w;
                    windSamples++;
                    const double f = *w / (5.0 * info.windStrength);
                    if (f >= 0.75)
                        windHead++;
                    else if (f <= 0.25)
                        windTail++;
                    else
                        windSide++;
                }
            }
        }
        if (l.heart > 0) {
            withHeart++;
            sumHeart += l.heart;
            maxHeart = qMax(maxHeart, (double)l.heart);
            zones[heartRateZone(l.heart / hrMax * 100.0)] += 1;
        }
    }

    // samples: every second for rides up to one hour, every few seconds for longer ones
    const int step = qMax(1, (int)std::ceil(n / 3600.0));
    QJsonArray at, ad, ao, ae, av, ap, ac, ah, ar, ag, aw;
    auto addSample = [&](int i) {
        const SessionLine &l = session.at(i);
        at.append((qint64)l.elapsedTime);
        ad.append(rd[i] >= 0 ? (qint64)std::lround(rd[i]) : -1);
        ao.append((qint64)std::lround(l.distance * 1000.0));
        double ele = qQNaN();
        if (rd[i] >= 0)
            ele = route.elevationAt(rd[i]);
        else if (l.coordinate.isValid() && !qIsNaN(l.coordinate.altitude()))
            ele = l.coordinate.altitude();
        ae.append(qIsNaN(ele) ? QJsonValue() : QJsonValue(round1(ele)));
        av.append(round1(l.speed));
        ap.append((int)l.watt);
        ac.append((int)l.cadence);
        ah.append((int)l.heart);
        ar.append((int)l.resistance);
        ag.append((int)l.inclination);
        const auto w = windPercent.constFind(l.elapsedTime);
        aw.append(w != windPercent.constEnd() && *w >= 0 ? QJsonValue(round1(*w)) : QJsonValue(-1));
    };
    for (int i = 0; i < n; i += step)
        addSample(i);
    if ((n - 1) % step)
        addSample(n - 1);
    QJsonObject samples;
    samples[QStringLiteral("t")] = at;
    samples[QStringLiteral("d")] = ad;
    samples[QStringLiteral("o")] = ao;
    samples[QStringLiteral("e")] = ae;
    samples[QStringLiteral("v")] = av;
    samples[QStringLiteral("p")] = ap;
    samples[QStringLiteral("c")] = ac;
    samples[QStringLiteral("h")] = ah;
    samples[QStringLiteral("r")] = ar;
    samples[QStringLiteral("g")] = ag;
    samples[QStringLiteral("w")] = aw;

    // id: start time of the ride
    QDateTime start = session.first().time;
    if (!start.isValid())
        start = QDateTime::currentDateTime().addSecs(-(qint64)session.last().elapsedTime);
    QDir().mkpath(folder() + QStringLiteral("rides"));
    QString id = start.toString(QStringLiteral("yyyyMMdd-HHmmss"));
    for (int k = 2; QFile::exists(folder() + QStringLiteral("rides/") + id + QStringLiteral(".json")); k++)
        id = start.toString(QStringLiteral("yyyyMMdd-HHmmss")) + QStringLiteral("-") + QString::number(k);

    const SessionLine &last = session.last();
    QJsonObject summary;
    summary[QStringLiteral("id")] = id;
    summary[QStringLiteral("start")] = start.toString(Qt::ISODate);
    summary[QStringLiteral("end")] = last.time.isValid() ? last.time.toString(Qt::ISODate)
                                                         : start.addSecs(last.elapsedTime).toString(Qt::ISODate);
    summary[QStringLiteral("duration")] = (qint64)last.elapsedTime;
    summary[QStringLiteral("moving")] = moving;
    summary[QStringLiteral("distance")] = (qint64)std::lround(last.distance * 1000.0);
    summary[QStringLiteral("ascent")] = (qint64)std::lround(last.elevationGain);
    summary[QStringLiteral("kcal")] = (qint64)std::lround(last.calories);
    summary[QStringLiteral("kj")] = (qint64)std::lround(joules / 1000.0);
    summary[QStringLiteral("avgSpeed")] = moving ? round1(sumSpeed / moving) : 0.0;
    summary[QStringLiteral("maxSpeed")] = round1(maxSpeed);
    summary[QStringLiteral("avgPower")] = moving ? (qint64)std::lround(sumPower / moving) : 0;
    summary[QStringLiteral("maxPower")] = (qint64)std::lround(maxPower);
    summary[QStringLiteral("avgCadence")] = moving ? (qint64)std::lround(sumCadence / moving) : 0;
    summary[QStringLiteral("avgLevel")] = moving ? round1(sumLevel / moving) : 0.0;
    summary[QStringLiteral("avgHr")] = withHeart ? (qint64)std::lround(sumHeart / withHeart) : 0;
    summary[QStringLiteral("maxHr")] = (qint64)std::lround(maxHeart);
    summary[QStringLiteral("hrMax")] = (qint64)std::lround(hrMax);
    QJsonArray zoneSeconds;
    for (double z : zones)
        zoneSeconds.append((qint64)std::lround(z));
    summary[QStringLiteral("hrZones")] = zoneSeconds;
    summary[QStringLiteral("device")] = info.deviceName;
    summary[QStringLiteral("step")] = step;

    if (onRoute) {
        // time from the start of the route to its end (or to the farthest point reached)
        const double length = route.length();
        const double tolerance = qMax(50.0, length * 0.005);
        const bool finished = reached >= length - tolerance;
        const double startT = session.at(routeStart).elapsedTime;
        double time = session.at(routeEnd).elapsedTime - startT;
        if (finished) {
            const double target = qMin(reached, length - 1.0);
            for (int i = routeStart + 1; i < n; i++) {
                if (rd[i] < target)
                    continue;
                int j = i - 1;
                while (j > routeStart && rd[j] < 0)
                    j--;
                const double t0 = session.at(j).elapsedTime, t1 = session.at(i).elapsedTime;
                const double d0 = qMax(0.0, rd[j]), d1 = rd[i];
                time = (d1 > d0 ? t0 + (target - d0) / (d1 - d0) * (t1 - t0) : t1) - startT;
                break;
            }
        }
        QJsonObject r;
        r[QStringLiteral("key")] = routeKey(info.gpxFile);
        r[QStringLiteral("file")] = info.gpxFile;
        r[QStringLiteral("name")] = route.name();
        r[QStringLiteral("length")] = (qint64)std::lround(length);
        r[QStringLiteral("start")] = (qint64)std::lround(startT);
        r[QStringLiteral("reached")] = (qint64)std::lround(reached);
        r[QStringLiteral("finished")] = finished;
        r[QStringLiteral("time")] = (qint64)std::lround(time);
        summary[QStringLiteral("route")] = r;
    }
    if (info.windStrength > 0 && windSamples > 0) {
        QJsonObject w;
        w[QStringLiteral("strength")] = info.windStrength;
        w[QStringLiteral("from")] = (qint64)std::lround(info.windFrom);
        w[QStringLiteral("avgPct")] = round1(windSum / windSamples);
        w[QStringLiteral("head")] = (qint64)std::lround(100.0 * windHead / windSamples);
        w[QStringLiteral("side")] = (qint64)std::lround(100.0 * windSide / windSamples);
        w[QStringLiteral("tail")] = (qint64)std::lround(100.0 * windTail / windSamples);
        summary[QStringLiteral("wind")] = w;
    }

    QJsonObject ride;
    ride[QStringLiteral("v")] = 1;
    ride[QStringLiteral("summary")] = summary;
    ride[QStringLiteral("samples")] = samples;
    if (!writeJsonFile(folder() + QStringLiteral("rides/") + id + QStringLiteral(".json"), ride)) {
        qDebug() << QStringLiteral("FunRun: could not write the ride") << id;
        return QString();
    }

    // index: newest first (ids are the start times)
    QJsonArray rides = listRides();
    QList<QJsonObject> all;
    all.append(summary);
    for (const QJsonValue &v : qAsConst(rides)) {
        if (v.toObject().value(QStringLiteral("id")).toString() != id)
            all.append(v.toObject());
    }
    std::stable_sort(all.begin(), all.end(), [](const QJsonObject &a, const QJsonObject &b) {
        return a.value(QStringLiteral("id")).toString() > b.value(QStringLiteral("id")).toString();
    });
    QJsonArray updated;
    for (const QJsonObject &o : qAsConst(all))
        updated.append(o);
    writeIndex(updated);
    qDebug() << QStringLiteral("FunRun: ride saved") << id << QStringLiteral("samples") << at.size()
             << QStringLiteral("on route") << onRoute;
    return id;
}

QJsonArray FunRunStore::listRoutes() {
    const QString cacheFile = folder() + QStringLiteral("routes.json");
    const QJsonObject cache = readJsonFile(cacheFile).value(QStringLiteral("routes")).toObject();
    QJsonObject newCache;
    bool changed = false;
    QList<QJsonObject> routes;
    QDir dir(homeform::getWritableAppDir() + QStringLiteral("gpx"));
    const QFileInfoList files =
        dir.entryInfoList(QStringList() << QStringLiteral("*.gpx") << QStringLiteral("*.GPX"), QDir::Files, QDir::Name);
    for (const QFileInfo &fi : files) {
        const QString path = fi.absoluteFilePath();
        const qint64 size = fi.size(), mtime = fi.lastModified().toMSecsSinceEpoch();
        QJsonObject entry = cache.value(path).toObject();
        if (entry.value(QStringLiteral("size")).toDouble() != (double)size ||
            entry.value(QStringLiteral("mtime")).toDouble() != (double)mtime) {
            FunRunRoute route;
            route.load(path);
            entry = QJsonObject();
            entry[QStringLiteral("size")] = size;
            entry[QStringLiteral("mtime")] = mtime;
            entry[QStringLiteral("info")] = route.describe();
            changed = true;
        }
        newCache[path] = entry;
        QJsonObject info = entry.value(QStringLiteral("info")).toObject();
        if (!info.contains(QStringLiteral("length")))
            continue; // not a usable route
        info[QStringLiteral("file")] = path;
        info[QStringLiteral("key")] = routeKey(path);
        routes.append(info);
    }
    if (changed || newCache.size() != cache.size()) {
        QDir().mkpath(folder());
        QJsonObject out;
        out[QStringLiteral("v")] = 1;
        out[QStringLiteral("routes")] = newCache;
        writeJsonFile(cacheFile, out);
    }
    std::sort(routes.begin(), routes.end(), [](const QJsonObject &a, const QJsonObject &b) {
        return a.value(QStringLiteral("name")).toString().toLower() < b.value(QStringLiteral("name")).toString().toLower();
    });
    QJsonArray out;
    for (const QJsonObject &o : qAsConst(routes))
        out.append(o);
    return out;
}

QJsonArray FunRunStore::listRides() {
    const QJsonObject index = readJsonFile(folder() + QStringLiteral("rides.json"));
    if (index.value(QStringLiteral("rides")).isArray())
        return index.value(QStringLiteral("rides")).toArray();

    // no index (yet): rebuild it from the ride files, newest first
    QDir dir(folder() + QStringLiteral("rides"));
    QStringList files = dir.entryList(QStringList() << QStringLiteral("*.json"), QDir::Files, QDir::Name);
    QJsonArray rides;
    for (int i = files.size() - 1; i >= 0; i--) {
        const QJsonObject summary = readJsonFile(dir.filePath(files.at(i))).value(QStringLiteral("summary")).toObject();
        if (!summary.isEmpty())
            rides.append(summary);
    }
    if (!rides.isEmpty())
        writeIndex(rides);
    return rides;
}

QJsonObject FunRunStore::loadRide(const QString &id) {
    if (!validId(id))
        return QJsonObject();
    return readJsonFile(folder() + QStringLiteral("rides/") + id + QStringLiteral(".json"));
}

bool FunRunStore::deleteRide(const QString &id) {
    if (!validId(id))
        return false;
    const bool removed = QFile::remove(folder() + QStringLiteral("rides/") + id + QStringLiteral(".json"));
    QJsonArray rides = listRides(), kept;
    for (const QJsonValue &v : qAsConst(rides)) {
        if (v.toObject().value(QStringLiteral("id")).toString() != id)
            kept.append(v);
    }
    writeIndex(kept);
    return removed;
}

// ------------------------------------------------------------------ ghost rider

namespace {
// y at x on a polyline with ascending xs (clamped at both ends)
double interpolate(const QVector<double> &xs, const QVector<double> &ys, double x) {
    if (xs.isEmpty())
        return 0;
    if (x <= xs.first())
        return ys.first();
    if (x >= xs.last())
        return ys.last();
    int lo = 0, hi = xs.size() - 1;
    while (hi - lo > 1) {
        const int mid = (lo + hi) / 2;
        if (xs[mid] <= x)
            lo = mid;
        else
            hi = mid;
    }
    const double u = xs[hi] > xs[lo] ? (x - xs[lo]) / (xs[hi] - xs[lo]) : 0;
    return ys[lo] + u * (ys[hi] - ys[lo]);
}
} // namespace

void FunRunGhost::follow(const QString &gpxFile, const QString &newMode) {
    if (gpxFile == routeFile && newMode == mode && !dirty)
        return;
    const bool newRoute = gpxFile != routeFile;
    routeFile = gpxFile;
    mode = newMode;
    dirty = false;
    if (newRoute) {
        route.load(gpxFile);
        startElapsed = -1;
        myD = -1;
    }
    load();
}

void FunRunGhost::restart() {
    startElapsed = -1;
    myD = -1;
    dirty = true;
}

void FunRunGhost::load() {
    gT.clear();
    gD.clear();
    ghostLabel.clear();
    ghostTotal = -1;
    if (!route.valid() || mode == QStringLiteral("off"))
        return;
    const QString key = FunRunStore::routeKey(routeFile);
    const bool last = mode == QStringLiteral("last");
    QJsonObject pick;
    const QJsonArray rides = FunRunStore::listRides();
    for (const QJsonValue &v : rides) {
        const QJsonObject o = v.toObject(), r = o.value(QStringLiteral("route")).toObject();
        if (r.value(QStringLiteral("key")).toString() != key)
            continue;
        if (last) {
            pick = o; // the list is newest first
            break;
        }
        if (!r.value(QStringLiteral("finished")).toBool())
            continue;
        if (pick.isEmpty() || r.value(QStringLiteral("time")).toDouble() <
                                  pick.value(QStringLiteral("route")).toObject().value(QStringLiteral("time")).toDouble())
            pick = o;
    }
    if (pick.isEmpty())
        return;
    const QJsonObject samples =
        FunRunStore::loadRide(pick.value(QStringLiteral("id")).toString()).value(QStringLiteral("samples")).toObject();
    const QJsonArray t = samples.value(QStringLiteral("t")).toArray(), d = samples.value(QStringLiteral("d")).toArray();
    double t0 = -1, dmax = -1;
    for (int i = 0; i < t.size() && i < d.size(); i++) {
        const double di = d.at(i).toDouble(-1);
        if (di < 0)
            continue;
        if (t0 < 0)
            t0 = t.at(i).toDouble();
        if (di < dmax)
            continue; // never backwards
        dmax = di;
        gT.append(t.at(i).toDouble() - t0);
        gD.append(di);
    }
    if (gT.size() < 2) {
        gT.clear();
        gD.clear();
        return;
    }
    // same GPX: lengths match; if the file changed a little, stretch the ghost onto this route
    const QJsonObject r = pick.value(QStringLiteral("route")).toObject();
    const double length = r.value(QStringLiteral("length")).toDouble();
    if (length > 0 && std::fabs(length - route.length()) > 1) {
        const double k = route.length() / length;
        for (double &x : gD)
            x *= k;
    }
    ghostLabel = last ? QStringLiteral("Letzte Fahrt") : QStringLiteral("Bestzeit");
    ghostTotal = r.value(QStringLiteral("finished")).toBool() ? r.value(QStringLiteral("time")).toDouble() : -1;
    qDebug() << QStringLiteral("FunRun ghost:") << ghostLabel << pick.value(QStringLiteral("id")).toString()
             << QStringLiteral("time") << ghostTotal;
}

void FunRunGhost::measure(const QGeoCoordinate &position, quint32 elapsed) {
    if (!route.valid() || !position.isValid() || (position.latitude() == 0 && position.longitude() == 0))
        return;
    double off = 0;
    const double d = route.project(position.latitude(), position.longitude(), myD, off);
    if (off > 80)
        return;
    if (startElapsed < 0)
        startElapsed = elapsed; // first second on the route: the clock of the comparison starts
    myD = d;
    if (gT.isEmpty())
        return;
    const double t = elapsed - startElapsed;
    ghostD = interpolate(gT, gD, t);
    gapS = myD <= gD.last() ? interpolate(gD, gT, myD) - t : qQNaN();
}
