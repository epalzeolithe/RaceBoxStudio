import Foundation

/// Archive automatique des sessions téléchargées : un CSV et un GPX par session dans Documents/RaceBoxStudio.
nonisolated enum SessionArchive {
    struct Report: Sendable {
        var folder: URL?
        var written: [String] = []
        var unchanged: [String] = []
        var failures: [String] = []
    }

    /// Documents/RaceBoxStudio (le dossier est créé au besoin).
    static func folder() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let folder = documents.appending(path: "RaceBoxStudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Écrit les fichiers de chaque session. Un fichier déjà archivé de même taille est laissé tel quel
    /// (même session téléchargée deux fois) ; s'il diffère (mémoire plus longue), il est remplacé.
    /// À appeler hors du fil principal : générer le CSV d'une heure de vol prend un moment.
    static func archive(_ sessions: [RecordingSession]) -> Report {
        var report = Report()
        let folder: URL
        do {
            folder = try Self.folder()
            report.folder = folder
        } catch {
            report.failures.append(error.localizedDescription)
            return report
        }
        // Deux sessions au même nom (sans date, ou démarrées à la même seconde) ne doivent pas s'écraser.
        var used = Set<String>()
        for session in sessions where !session.samples.isEmpty {
            let base = session.fileStem
            var stem = base
            var suffix = 1
            while !used.insert(stem).inserted {
                suffix += 1
                stem = "\(base)-\(suffix)"
            }
            for (name, contents) in [(stem + ".csv", session.csv()), (stem + ".gpx", session.gpx())] {
                let url = folder.appending(path: name)
                let data = Data(contents.utf8)
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == data.count {
                    report.unchanged.append(name)
                    continue
                }
                do {
                    try data.write(to: url, options: .atomic)
                    report.written.append(name)
                } catch {
                    report.failures.append("\(name) : \(error.localizedDescription)")
                }
            }
        }
        return report
    }
}
