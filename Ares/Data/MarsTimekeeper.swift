import Foundation
import Combine

class MarsTimekeeper: ObservableObject {
    @Published private(set) var mtc: String = ""
    @Published private(set) var marsSolDate: Double = 0
    @Published private(set) var marsYear: Int = 0
    @Published private(set) var solarLongitude: Double = 0
    @Published private(set) var lightDelay: String = ""
    @Published private(set) var distanceToSun: String = ""
    @Published private(set) var distanceToEarth: String = ""
    @Published private(set) var orbitalVelocity: String = ""

    private var timer: AnyCancellable?

    let activeOrbiters: Int
    let activeSurfaceMissions: Int

    init() {
        activeOrbiters = 7
        activeSurfaceMissions = 2
        update()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.update() }
    }

    private func update() {
        let now = Date()
        let jd = julianDate(now)
        let msd = marsSolDate(jd: jd)
        let mtcHours = (msd - msd.rounded(.down)) * 24

        self.marsSolDate = msd
        self.mtc = formatMTC(hours: mtcHours)
        self.marsYear = marsYear(msd: msd)
        self.solarLongitude = solarLongitude(jd: jd)

        let (dSun, dEarth) = marsDistances(jd: jd)
        let lightTimeSec = dEarth * 499.004784 // seconds per AU
        self.lightDelay = formatDuration(seconds: lightTimeSec)
        self.distanceToSun = formatDistance(au: dSun)
        self.distanceToEarth = formatDistance(au: dEarth)
        self.orbitalVelocity = formatVelocity(au: dSun)
    }

    // MARK: - Julian Date

    private func julianDate(_ date: Date) -> Double {
        let ti = date.timeIntervalSince1970
        return (ti / 86400.0) + 2440587.5
    }

    // MARK: - Mars Sol Date (Allison & McEwen 2000)

    private func marsSolDate(jd: Double) -> Double {
        let tt = jd + (37 + 32.184) / 86400.0 // TT offset
        let j2000 = tt - 2451545.0
        return (((j2000 - 4.5) / 1.0274912517) + 44796.0 - 0.0009626)
    }

    // MARK: - Mars Year (Clancy et al. convention, MY1 starts April 11, 1955)

    private func marsYear(msd: Double) -> Int {
        // MSD 0 = Dec 29, 1873. MY1 starts at Ls=0, ~MSD 14186
        let mySince1 = (msd - 14186.0) / 668.6
        return Int(mySince1) + 1
    }

    // MARK: - Solar Longitude (Ls) — simplified

    private func solarLongitude(jd: Double) -> Double {
        // Mars mean anomaly (degrees)
        let M = (19.3871 + 0.52402075 * (jd - 2451545.0)).truncatingRemainder(dividingBy: 360)
        let Mrad = M * .pi / 180
        // Equation of center
        let eoc = 10.691 * sin(Mrad) + 0.623 * sin(2 * Mrad) + 0.050 * sin(3 * Mrad)
        // Areocentric solar longitude
        let alphaFMS = 270.3863 + 0.52403840 * (jd - 2451545.0)
        var ls = (alphaFMS + eoc).truncatingRemainder(dividingBy: 360)
        if ls < 0 { ls += 360 }
        return ls
    }

    // MARK: - Mars-Sun and Mars-Earth distances (Keplerian approximation)

    private func marsDistances(jd: Double) -> (sun: Double, earth: Double) {
        let d = jd - 2451545.0

        // Mars orbital elements
        let marsA = 1.52368
        let marsE = 0.0934
        let marsM0 = 19.3871 // deg at J2000
        let marsN = 0.5240208 // deg/day
        let marsLongPeri = 336.04 // longitude of perihelion, deg
        let marsLongNode = 49.56
        let marsI = 1.85 * Double.pi / 180

        // Earth orbital elements
        let earthA = 1.00000
        let earthE = 0.01671
        let earthM0 = 357.5291 // deg at J2000
        let earthN = 0.9856474 // deg/day
        let earthLongPeri = 102.94

        func solveKepler(M: Double, e: Double) -> Double {
            var E = M
            for _ in 0..<10 {
                E = M + e * sin(E)
            }
            return E
        }

        func helioPos(a: Double, e: Double, M0: Double, n: Double, longPeri: Double, longNode: Double, inc: Double) -> (x: Double, y: Double, z: Double) {
            var M = (M0 + n * d).truncatingRemainder(dividingBy: 360)
            if M < 0 { M += 360 }
            let Mrad = M * .pi / 180
            let E = solveKepler(M: Mrad, e: e)
            let nu = atan2(sqrt(1 - e * e) * sin(E), cos(E) - e)
            let r = a * (1 - e * cos(E))
            let omega = (longPeri - longNode) * .pi / 180
            let Omega = longNode * .pi / 180
            let cosNu = cos(nu + omega)
            let sinNu = sin(nu + omega)
            let x = r * (cos(Omega) * cosNu - sin(Omega) * sinNu * cos(inc))
            let y = r * (sin(Omega) * cosNu + cos(Omega) * sinNu * cos(inc))
            let z = r * sinNu * sin(inc)
            return (x, y, z)
        }

        let mars = helioPos(a: marsA, e: marsE, M0: marsM0, n: marsN, longPeri: marsLongPeri, longNode: marsLongNode, inc: marsI)
        let earth = helioPos(a: earthA, e: earthE, M0: earthM0, n: earthN, longPeri: earthLongPeri, longNode: 0, inc: 0)

        let dSun = sqrt(mars.x * mars.x + mars.y * mars.y + mars.z * mars.z)
        let dx = mars.x - earth.x
        let dy = mars.y - earth.y
        let dz = mars.z - earth.z
        let dEarth = sqrt(dx * dx + dy * dy + dz * dz)

        return (dSun, dEarth)
    }

    // MARK: - Orbital velocity (vis-viva)

    private func formatVelocity(au dSun: Double) -> String {
        let mu = 1.32712440018e20 // m³/s², Sun
        let a = 1.52368 * 1.496e11 // semi-major axis in meters
        let r = dSun * 1.496e11 // current distance in meters
        let v = sqrt(mu * (2 / r - 1 / a)) / 1000 // km/s
        if UserDefaults.standard.bool(forKey: "useImperialUnits") {
            return String(format: "%.1f mi/s", v * 0.621371)
        }
        return String(format: "%.1f km/s", v)
    }

    // MARK: - Formatting

    private func formatMTC(hours: Double) -> String {
        let h = Int(hours)
        let m = Int((hours - Double(h)) * 60)
        let s = Int((hours - Double(h) - Double(m) / 60.0) * 3600)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func formatDuration(seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
    }

    private func formatDistance(au: Double) -> String {
        let km = au * 149_597_870.7
        if UserDefaults.standard.bool(forKey: "useImperialUnits") {
            let miles = km * 0.621371
            if miles >= 1_000_000 {
                return String(format: "%.0f mi", miles.rounded())
                    .replacingOccurrences(of: "(?<=\\d)(?=(\\d{3})+(?!\\d))", with: ",", options: .regularExpression)
            }
            return String(format: "%.0f mi", miles)
        }
        if km >= 1_000_000 {
            return String(format: "%.0f km", km.rounded())
                .replacingOccurrences(of: "(?<=\\d)(?=(\\d{3})+(?!\\d))", with: ",", options: .regularExpression)
        }
        return String(format: "%.0f km", km)
    }
}
