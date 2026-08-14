import Foundation

/// Notices when something other than this app changes the sheets.
///
/// Two things are watched, because they answer different questions. The folder
/// fires when a sheet is added, removed, or replaced — and an atomic write,
/// which is what most editors and cloud clients do, counts as replacing. The
/// open sheet is watched as well, for the writer that edits it in place and so
/// never touches the folder at all.
///
/// Changes arrive in bursts, so they are collected for a moment before anyone
/// is told: a cloud client bringing down six sheets should be one reload.
@MainActor
public final class FolderWatcher {
	private var sources: [DispatchSourceFileSystemObject] = []
	private var settling: Task<Void, Never>?

	private let queue = DispatchQueue(label: "myo.folder-watcher")

	public var onChange: () -> Void = {}

	public init() {}

	public func watch(folder: URL?, file: URL?) {
		stop()

		for url in [folder, file].compactMap({ $0 }) {
			guard let source = FolderWatcher.makeSource(for: url, queue: queue, onEvent: { [weak self] in
				Task { @MainActor in self?.settle() }
			}) else { continue }

			sources.append(source)
			source.resume()
		}
	}

	public func stop() {
		settling?.cancel()
		settling = nil

		for source in sources { source.cancel() }
		sources.removeAll()
	}

	deinit {
		for source in sources { source.cancel() }
	}

	/// Built outside the actor on purpose.
	///
	/// Dispatch runs these handlers on its own queue, and a closure written
	/// inside a `@MainActor` type carries that isolation with it — so the
	/// handler traps the moment dispatch calls it from anywhere else. Taking
	/// them as `@Sendable` here keeps them free of the actor.
	private nonisolated static func makeSource(
		for url: URL,
		queue: DispatchQueue,
		onEvent: @escaping @Sendable () -> Void
	) -> DispatchSourceFileSystemObject? {
		let descriptor = open(url.path, O_EVTONLY)
		guard descriptor >= 0 else { return nil }

		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: descriptor,
			eventMask: [.write, .rename, .delete, .extend, .attrib],
			queue: queue)

		source.setEventHandler(handler: onEvent)
		source.setCancelHandler { close(descriptor) }

		return source
	}

	/// One reload for a burst of changes, not one per file.
	private func settle() {
		settling?.cancel()

		settling = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(300))
			guard !Task.isCancelled else { return }
			self?.onChange()
		}
	}
}
