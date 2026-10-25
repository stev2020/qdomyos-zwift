#ifndef FUNRUNSTORE_H
#define FUNRUNSTORE_H

#include "sessionline.h"

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

  private:
    static QString folder();
    static bool validId(const QString &id);
    static void writeIndex(const QJsonArray &rides);
};

#endif // FUNRUNSTORE_H
