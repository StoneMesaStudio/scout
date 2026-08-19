import Foundation

/// The paths a file search pretends do not exist.
///
/// This is the fix for the complaint that started the app: searching "service" returned three
/// identical `service-worker` folders out of `node_modules` before it returned the actual service
/// records. Down-ranking that noise is not enough — a big enough pile of it still floats. It gets
/// removed instead, and the count of what was removed is shown so nothing disappears silently.
public struct Exclusions: Sendable, Equatable {

    /// Directory names that mean "a machine put this here", wherever they appear in a path.
    public static let developerDirectories: Set<String> = [
        "node_modules", ".git", ".svn", "DerivedData", "Pods", "Carthage", ".build",
        ".swiftpm", "vendor", "dist", "build", ".next", ".nuxt", ".venv", "venv",
        "__pycache__", ".gradle", ".cache", ".terraform", "bower_components",
    ]

    /// Absolute roots that hold only system and application internals.
    ///
    /// `~/Library` is in here, which is why Mail and Messages need their own lanes rather than
    /// turning up in a file search — their stores live under it and would be unreadable noise
    /// even if they did appear.
    public static func systemRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            "/System", "/Library", "/usr", "/bin", "/sbin", "/opt", "/private", "/cores",
            "/Applications",                      // apps are their own lane
            home.appending(path: "Library").path, // caches, containers, mail, messages
        ]
    }

    /// Skip files whose name starts with a dot.
    public var excludeHidden: Bool
    /// Skip anything inside a `developerDirectories` folder.
    public var excludeDeveloperNoise: Bool
    /// Skip anything under a `systemRoots` path.
    public var excludeSystemInternals: Bool
    /// Extra folders the user chose to ignore.
    public var userExcluded: [URL]

    public init(
        excludeHidden: Bool = true,
        excludeDeveloperNoise: Bool = true,
        excludeSystemInternals: Bool = true,
        userExcluded: [URL] = []
    ) {
        self.excludeHidden = excludeHidden
        self.excludeDeveloperNoise = excludeDeveloperNoise
        self.excludeSystemInternals = excludeSystemInternals
        self.userExcluded = userExcluded
    }

    /// Everything on, which is what a file search uses by default.
    public static let standard = Exclusions()
    /// Nothing hidden — what "Show hidden matches" turns on.
    public static let none = Exclusions(
        excludeHidden: false,
        excludeDeveloperNoise: false,
        excludeSystemInternals: false
    )

    public func excludes(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let components = url.pathComponents

        if excludeHidden, components.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." }) {
            return true
        }

        if excludeDeveloperNoise {
            // Only *containing* folders count. A file the user named `build.txt` is theirs;
            // a file sitting inside a folder called `build` is not.
            for component in components.dropLast() where Self.developerDirectories.contains(component) {
                return true
            }
        }

        if excludeSystemInternals {
            let path = url.path
            for root in Self.systemRoots(home: home) where path.hasPrefix(root + "/") {
                return true
            }
        }

        for folder in userExcluded where url.path.hasPrefix(folder.path + "/") {
            return true
        }

        return false
    }
}
