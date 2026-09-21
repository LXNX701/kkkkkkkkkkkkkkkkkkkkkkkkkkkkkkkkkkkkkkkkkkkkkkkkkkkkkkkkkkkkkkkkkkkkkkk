import Foundation

/// Dedicated runner for packages stored in the app's `Textures/` bundle folder.
///
/// This is intentionally separate from PatchSlotRunner so texture resources:
/// - can only resolve from `Textures/`;
/// - never fall back to FF / FF Max folders;
/// - expose only Inject / Restore operations;
/// - keep the existing FF / FF Max runner untouched.
enum TexturePatchRunner {

    static func inject(
        fileName: String,
        configuredPassword: String
    ) -> Result<String, Error> {
        do {
            let url = try bundledTextureURL(fileName: fileName)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])

            let password: String? = configuredPassword == "0"
                ? nil
                : configuredPassword

            // Decode the exact texture package from Textures/.
            // Schema validation remains centralized in PatchPackageCodec.
            let decoded = try PatchPackageCodec.decode(
                data,
                password: password
            )

            _ = try DevicePatchService.apply(project: decoded.project)

            return .success("Textura injetada. Backup original criado.")
        } catch {
            return .failure(error)
        }
    }

    static func restore(
        fileName: String,
        configuredPassword: String
    ) -> Result<String, Error> {
        do {
            let url = try bundledTextureURL(fileName: fileName)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])

            let password: String? = configuredPassword == "0"
                ? nil
                : configuredPassword

            let decoded = try PatchPackageCodec.decode(
                data,
                password: password
            )

            guard let receipt = DevicePatchService.latestReceipt(
                projectID: decoded.project.id
            ) else {
                throw TexturePatchRunnerError.noBackup
            }

            try DevicePatchService.restore(receipt: receipt)

            return .success("Textura restaurada. Original recuperado.")
        } catch {
            return .failure(error)
        }
    }

    static func message(for error: Error) -> String {
        if let textureError = error as? TexturePatchRunnerError {
            switch textureError {
            case .missingFile(let name):
                return "Textura não encontrada: \(name)"
            case .noBackup:
                return "Não existe backup para esta textura."
            }
        }

        if let patchError = error as? PatchPackageError {
            switch patchError {
            case .unsupportedVersion:
                return "Falha no patch: versão do pacote não suportada."
            default:
                return "Falha no patch: \(patchError.localizationKey)"
            }
        }

        return "Falha: \(error.localizedDescription)"
    }

    private static func bundledTextureURL(fileName: String) throws -> URL {
        let fileManager = FileManager.default
        let expectedName = (fileName as NSString).lastPathComponent

        guard expectedName == fileName else {
            throw TexturePatchRunnerError.missingFile(expectedName)
        }

        guard let bundleRoot = Bundle.main.resourceURL else {
            throw TexturePatchRunnerError.missingFile(expectedName)
        }

        let texturesDirectory = bundleRoot.appendingPathComponent(
            "Textures",
            isDirectory: true
        )

        let url = texturesDirectory.appendingPathComponent(
            expectedName,
            isDirectory: false
        )

        guard fileManager.fileExists(atPath: url.path) else {
            throw TexturePatchRunnerError.missingFile(expectedName)
        }

        return url
    }

    private enum TexturePatchRunnerError: Error {
        case missingFile(String)
        case noBackup
    }
}
