#ifndef FUNRUNSTORE_H
#define FUNRUNSTORE_H

#include "sessionline.h"

#include <QGeoCoordinate>

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QVector>

/**
 * FunRun: a GPX route in a flat metric frame around its first point, enough to find where on the route a position
 * is. Distances along the route are measured the same way for every ride, so rides of the same route compare.
 */
class FunRunRoute {
  public:
    bool load(const QString &gpxFile);
    bool valid() const { return s.size() >= 2 && s.last() > 50; }
    double length() const { return s.isEmpty() ? 0 : s.last(); }
    QString name() const { return routeName; }
    QString file() const { return routeFile; }
    double elevationAt(double d) const;
    // Distance along the route of the point closest to lat/lon. Searches around `hint` first (-1: everywhere).
    // `off` gets the distance between the position and the route, in metres.
    double project(double lat, double lon, double hint, double &off) const;
    // name, length, climbing, elevation range, outline (for a thumbnail) and elevation profile of the route
    QJsonObject describe() const;

  private:
    int segment(double d) const;
    QString routeName, routeFile;
    double lat0 = 0, lon0 = 0, kx = 1, ky = 1;
    QVector<double> x, y, s, e; // metres east and north of the first point, distance along the route, elevation
};

/**
 * FunRun: every ride is kept as a small JSON file in <app folder>/funrun/rides: a summary and samples every few
 * seconds (time, distance along the route, elevation, speed, power, cadence, heart rate, level, grade, wind).
 * The ride end screen, the ride history and the ghost rider on the map read them over the template web socket.
 */
class FunRunStore {
  public:
    struct RideInfo {
        QString gpxFile;      // route of the ride, empty for a free ride
        QString deviceName;
        int windStrength = 0; // 0 = off .. 4
        double windFrom = 0;  // degrees, 0 = north
        double hrMax = 190;   // bpm, for the heart rate zones
    };

    // Builds the ride from the session and writes it. Returns its id, empty when the ride is too short to keep.
    static QString saveRide(const QList<SessionLine> &session, const QHash<quint32, float> &windPercent,
                            const RideInfo &info);
    // Summaries of all rides, newest first
    static QJsonArray listRides();
    // A whole ride (summary and samples), an empty object when there is no such ride
    static QJsonObject loadRide(const QString &id);
    static bool deleteRide(const QString &id);
    // Name that recognises the same route again: the GPX file name without folder and extension, lower case
    static QString routeKey(const QString &gpxFile);
    // GPX routes in the app's gpx folder (described by FunRunRoute::describe, cached in funrun/routes.json)
    static QJsonArray listRoutes();
    // A new route from the FunRun pages ("Entdecken"): written to the gpx folder as <name>.gpx (another number when
    // a different file has that name). Returns the path, empty when the text is no GPX or cannot be written.
    static QString saveGpx(const QString &name, const QByteArray &gpx);
    // Text of a GPX file in the gpx folder or in funrun/ultra (nothing from other places), empty otherwise
    static QByteArray readGpx(const QString &file);

    // Long routes ridden in stages ("Langstrecken", e.g. ultra races): one JSON file each in funrun/ultra
    // (meta data, the track and the stages); the list leaves the tracks out
    static QJsonArray listUltra();
    static QJsonObject loadUltra(const QString &id);
    static bool saveUltra(const QJsonObject &project);
    // removes the project with its original GPX and the stage files it made in the gpx folder
    static bool deleteUltra(const QString &id);
    // moves a GPX of the gpx folder to funrun/ultra/<id>.gpx (the long route is not listed as one route). Returns the
    // new path, empty on failure
    static QString adoptUltraGpx(const QString &file, const QString &id);

  private:
    static QString folder();
    static bool validId(const QString &id);
    static bool validUltraId(const QString &id);
    static void writeIndex(const QJsonArray &rides);
};

/**
 * FunRun ghost rider: an earlier ride of the same route (best time or last ride) rides along. Every second the
 * current position on the route is compared with where the ghost was after the same time on the route.
 */
class FunRunGhost {
  public:
    // follows the current GPX file and the ghost setting ("best", "last", "off"): loads route and ghost on a change
    void follow(const QString &gpxFile, const QString &mode);
    // a new ride: the start of the route is looked for again, the ghost is loaded again (there may be a new best)
    void restart();
    // one second of the ride: position now and elapsed seconds of the session
    void measure(const QGeoCoordinate &position, quint32 elapsed);

    bool active() const { return !gT.isEmpty() && myD >= 0; }
    double routeLength() const { return route.length(); }
    double myDistance() const { return myD; }
    double ghostDistance() const { return ghostD; }
    // seconds ahead of the ghost (negative: behind); NaN where the ghost never got
    double gapSeconds() const { return gapS; }
    double gapMeters() const { return myD - ghostD; }
    // "Bestzeit" or "Letzte Fahrt"
    QString label() const { return ghostLabel; }
    // route time of the ghost ride in seconds, -1 when it did not get to the end
    double ghostTime() const { return ghostTotal; }

  private:
    void load();
    FunRunRoute route;
    QString routeFile, mode, ghostLabel;
    QVector<double> gT, gD; // ghost: time since the start of the route -> distance along the route
    double ghostTotal = -1;
    double myD = -1, ghostD = 0, gapS = 0;
    double startElapsed = -1;
    bool dirty = true;
};

#endif // FUNRUNSTORE_H
