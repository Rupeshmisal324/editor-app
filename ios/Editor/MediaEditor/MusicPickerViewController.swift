import UIKit
import AVFoundation

/// Rich music-selection sheet for the native video editor — replaces the
/// old plain UIAlertController list, per the user's explicit request to
/// match the RN AddPosts screen's music flow: live trending/search via the
/// same public iTunes/Apple endpoints (MusicAPI), a real list with per-row
/// artwork + play/pause preview, tap-a-row to select.
final class MusicPickerViewController: UIViewController {

  /// Fires once, when the user taps a row (not the play/pause button).
  var onSelect: ((MusicTrack) -> Void)?
  /// Fires once the picker has been dismissed (select or cancel).
  var onDismiss: (() -> Void)?

  private let searchBar = UISearchBar()
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let loadingLabel = UILabel()
  private let emptyLabel = UILabel()

  private var tracks: [MusicTrack] = []
  private var searchWorkItem: DispatchWorkItem?
  private var previewPlayer: AVPlayer?
  private var currentlyPlayingId: String?
  /// The exact request `emptyLabel`'s tap-to-retry should repeat — nil
  /// once a request succeeds (even with zero results, that's a real
  /// "nothing found", not a failure to retry).
  private var lastFailedLoad: (() -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = EditorDesignTokens.Colors.chromeBackground
    setUpSearchBar()
    setUpTableView()
    loadTrending()

    NotificationCenter.default.addObserver(
      self, selector: #selector(pausePreview),
      name: UIApplication.willResignActiveNotification, object: nil
    )
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    pausePreview()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      onDismiss?()
    }
  }

  private func setUpSearchBar() {
    searchBar.delegate = self
    searchBar.placeholder = "Search songs"
    searchBar.searchBarStyle = .minimal
    searchBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(searchBar)
    NSLayoutConstraint.activate([
      searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
    ])
  }

  private func setUpTableView() {
    tableView.backgroundColor = .clear
    tableView.separatorColor = EditorDesignTokens.Colors.divider
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(MusicPickerCell.self, forCellReuseIdentifier: "cell")
    tableView.rowHeight = 64
    tableView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(tableView)
    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    // Plain "Loading…" text, vertically centered — per the user's explicit
    // "remove these activity indicator from these screen and just keep
    // these loading ... text into vertical center" follow-up, replacing
    // the spinner+caption pair entirely.
    loadingLabel.text = "Loading…"
    loadingLabel.textColor = EditorDesignTokens.Colors.textSecondary
    loadingLabel.font = .systemFont(ofSize: 14, weight: .medium)
    loadingLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(loadingLabel)

    NSLayoutConstraint.activate([
      loadingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      loadingLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    // Tappable — per the user's "many time API not get called and get
    // more much time" report, a genuine network failure now surfaces a
    // real "couldn't load" message the user can act on instead of an
    // unexplained empty screen (or, before the MusicAPI timeout fix, an
    // effectively endless spinner).
    emptyLabel.textColor = EditorDesignTokens.Colors.textSecondary
    emptyLabel.font = .systemFont(ofSize: 14)
    emptyLabel.textAlignment = .center
    emptyLabel.numberOfLines = 0
    emptyLabel.isHidden = true
    emptyLabel.isUserInteractionEnabled = true
    emptyLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryTapped)))
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
      emptyLabel.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 40),
    ])
  }

  @objc private func retryTapped() {
    lastFailedLoad?()
  }

  /// Called every time the sheet opens (and when search is cleared): the
  /// last good list shows instantly, and a fresh request always runs.
  private func loadTrending() {
    let cached = MusicAPI.cachedTrending ?? []
    if cached.isEmpty {
      setLoading(true)
    } else {
      handle(.success(cached), retry: {})
    }
    MusicAPI.fetchTrendingWithFallback { [weak self] result in
      guard let self, self.searchBar.text?.isEmpty ?? true else { return }
      // Keep showing the cached list rather than replacing it with an
      // error or an empty result.
      if !cached.isEmpty {
        guard case .success(let tracks) = result, !tracks.isEmpty else { return }
      }
      self.handle(result, retry: { [weak self] in self?.loadTrending() })
    }
  }

  /// Shared success/failure handling for both trending and search — sets
  /// `tracks`/reloads the table on success, or shows the tappable
  /// "couldn't load" state (with `retry` wired to repeat the SAME
  /// request) on failure. `tracks` is always assigned before
  /// `setLoading(false)` runs, since that reads `tracks.isEmpty` to
  /// decide whether a successful-but-empty result should show "No songs
  /// found".
  private func handle(_ result: Result<[MusicTrack], Error>, retry: @escaping () -> Void) {
    switch result {
    case .success(let tracks):
      self.lastFailedLoad = nil
      self.tracks = tracks
      self.setLoading(false)
      self.tableView.reloadData()
    case .failure:
      self.lastFailedLoad = retry
      self.tracks = []
      self.setLoading(false)
      self.tableView.reloadData()
    }
  }

  private func setLoading(_ loading: Bool) {
    // With songs already on screen, the list just fades while the new
    // ones load ("Loading…" drawn over the rows was unreadable).
    tableView.alpha = loading && !tracks.isEmpty ? 0.45 : 1
    if loading {
      loadingLabel.isHidden = !tracks.isEmpty
      emptyLabel.isHidden = true
    } else {
      loadingLabel.isHidden = true
      emptyLabel.isHidden = !tracks.isEmpty
      emptyLabel.text = lastFailedLoad != nil ? "Couldn't load songs — tap to retry" : "No songs found"
    }
  }

  @objc private func pausePreview() {
    previewPlayer?.pause()
    previewPlayer = nil
    guard let id = currentlyPlayingId else { return }
    currentlyPlayingId = nil
    reloadRow(for: id)
  }

  private func reloadRow(for trackId: String) {
    guard let index = tracks.firstIndex(where: { $0.id == trackId }) else { return }
    tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
  }

  private func togglePlayPause(for track: MusicTrack) {
    if currentlyPlayingId == track.id {
      pausePreview()
      return
    }
    let previouslyPlayingId = currentlyPlayingId
    previewPlayer?.pause()
    previewPlayer = AVPlayer(url: track.audioURL)
    previewPlayer?.play()
    currentlyPlayingId = track.id
    if let previouslyPlayingId { reloadRow(for: previouslyPlayingId) }
    reloadRow(for: track.id)
  }
}

extension MusicPickerViewController: UISearchBarDelegate {
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    searchWorkItem?.cancel()
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      loadTrending()
      return
    }
    setLoading(true)
    let work = DispatchWorkItem { [weak self] in
      MusicAPI.search(term: trimmed) { [weak self] result in
        guard let self, self.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        self.handle(result, retry: { [weak self] in
          self?.searchBar(searchBar, textDidChange: trimmed)
        })
      }
    }
    searchWorkItem = work
    // Short pause after typing (results are cached per term, and a newer
    // search cancels the one in flight, so this can be quick).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
  }
}

extension MusicPickerViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    tracks.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! MusicPickerCell
    let track = tracks[indexPath.row]
    cell.configure(track: track, isPlaying: currentlyPlayingId == track.id)
    cell.onPlayPauseTapped = { [weak self] in self?.togglePlayPause(for: track) }
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let track = tracks[indexPath.row]
    pausePreview()
    onSelect?(track)
    dismiss(animated: true)
  }
}

/// One row: artwork + title/artist·duration + a play/pause preview button.
private final class MusicPickerCell: UITableViewCell {
  private let artworkView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let playPauseButton = UIButton(type: .system)

  var onPlayPauseTapped: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none

    artworkView.contentMode = .scaleAspectFill
    artworkView.clipsToBounds = true
    artworkView.layer.cornerRadius = 6
    artworkView.backgroundColor = EditorDesignTokens.Colors.elevatedSurface

    titleLabel.textColor = EditorDesignTokens.Colors.textPrimary
    titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
    subtitleLabel.textColor = EditorDesignTokens.Colors.textSecondary
    subtitleLabel.font = .systemFont(ofSize: 12)

    playPauseButton.tintColor = EditorDesignTokens.Colors.accent
    playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)

    let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    textStack.axis = .vertical
    textStack.spacing = 2

    [artworkView, textStack, playPauseButton].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview($0)
    }
    NSLayoutConstraint.activate([
      artworkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      artworkView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      artworkView.widthAnchor.constraint(equalToConstant: 44),
      artworkView.heightAnchor.constraint(equalToConstant: 44),

      textStack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 12),
      textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: playPauseButton.leadingAnchor, constant: -8),

      playPauseButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      playPauseButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      playPauseButton.widthAnchor.constraint(equalToConstant: 32),
      playPauseButton.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(track: MusicTrack, isPlaying: Bool) {
    RemoteImageLoader.load(track.albumArt, into: artworkView)
    titleLabel.text = track.title
    let minutes = Int(track.durationSeconds) / 60
    let seconds = Int(track.durationSeconds) % 60
    subtitleLabel.text = track.durationSeconds > 0
      ? "\(track.artist) · \(minutes):\(String(format: "%02d", seconds))"
      : track.artist
    playPauseButton.setImage(
      UIImage(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26)),
      for: .normal
    )
  }

  @objc private func playPauseTapped() {
    onPlayPauseTapped?()
  }
}
