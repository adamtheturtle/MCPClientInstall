import Foundation

extension MCPClientInstall {
    /// Prepares a complete JSON or Codex TOML update without writing it.
    ///
    /// The returned preview reflects the file at the time it was read. Call
    /// ``installServer(_:format:at:)`` to perform the update; installation
    /// re-prepares the configuration while holding its transaction lock.
    public static func prepareServerUpdate(
        _ server: MCPServerSpec,
        format: ConfigurationFormat,
        at url: URL,
    ) throws -> PreparedConfigUpdate {
        let sourceIdentity = try configurationIdentity(at: url)
        switch format {
        case .json:
            return try prepareJSONServerUpdate(server, at: url, sourceIdentity: sourceIdentity)
        case .codexTOML:
            return try prepareTOMLServerUpdate(server, at: url, sourceIdentity: sourceIdentity)
        }
    }

    private static func prepareJSONServerUpdate(
        _ server: MCPServerSpec,
        at url: URL,
        sourceIdentity: ConfigurationIdentity
    ) throws -> PreparedConfigUpdate {
        do {
            let root = try existingJSON(at: url)
            let merged = try jsonConfigByAddingServer(to: root, server: server)
            return try preparedUpdate(
                data: prettyJSONData(from: merged.root),
                format: .json,
                alreadyPresent: merged.alreadyPresent,
                sourceIdentity: sourceIdentity,
                at: url
            )
        } catch let error as InstallWorkflowError { throw error
        } catch let error as MCPServerSpec.ValidationError {
            throw InstallWorkflowError.invalidServer(error)
        } catch let error as JSONConfigError {
            throw InstallWorkflowError.invalidConfiguration(url: url, detail: String(describing: error))
        } catch let ConfigurationReadError.tooLarge(limit) {
            throw InstallWorkflowError.configurationTooLarge(url: url, limit: limit)
        } catch let error as CocoaError {
            throw InstallWorkflowError.invalidConfiguration(url: url, detail: error.localizedDescription)
        } catch {
            throw InstallWorkflowError.serializationFailed(url: url, detail: error.localizedDescription)
        }
    }

    private static func prepareTOMLServerUpdate(
        _ server: MCPServerSpec,
        at url: URL,
        sourceIdentity: ConfigurationIdentity
    ) throws -> PreparedConfigUpdate {
        let text: String
        do {
            text = try existingTOML(at: url)
        } catch let ConfigurationReadError.tooLarge(limit) {
            throw InstallWorkflowError.configurationTooLarge(url: url, limit: limit)
        } catch {
            throw InstallWorkflowError.readFailed(url: url, detail: error.localizedDescription)
        }
        do {
            let merged = try codexConfigByAddingServer(to: text, server: server)
            return try preparedUpdate(
                data: Data(merged.text.utf8),
                format: .codexTOML,
                alreadyPresent: merged.alreadyPresent,
                sourceIdentity: sourceIdentity,
                at: url
            )
        } catch let error as InstallWorkflowError {
            throw error
        } catch let error as MCPServerSpec.ValidationError {
            throw InstallWorkflowError.invalidServer(error)
        } catch {
            throw InstallWorkflowError.invalidConfiguration(url: url, detail: error.localizedDescription)
        }
    }

    private static func preparedUpdate(
        data: Data,
        format: ConfigurationFormat,
        alreadyPresent: Bool,
        sourceIdentity: ConfigurationIdentity,
        at url: URL
    ) throws -> PreparedConfigUpdate {
        try requireUnchanged(sourceIdentity, at: url)
        guard data.count <= maxConfigurationFileBytes else {
            throw InstallWorkflowError.configurationTooLarge(url: url, limit: maxConfigurationFileBytes)
        }
        return PreparedConfigUpdate(
            data: data,
            format: format,
            alreadyPresent: alreadyPresent,
            sourceIdentity: sourceIdentity
        )
    }

    static func existingTOML(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let data = try boundedConfigurationData(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}
