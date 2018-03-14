//
//  SessionsTableViewController.swift
//  WWDC
//
//  Created by Guilherme Rambo on 22/04/17.
//  Copyright © 2017 Guilherme Rambo. All rights reserved.
//

import Cocoa
import RxSwift
import RxCocoa
import RealmSwift
import ConfCore

protocol SessionsTableViewControllerDelegate: class {

    func sessionTableViewContextMenuActionWatch(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionUnWatch(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionFavorite(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionRemoveFavorite(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionDownload(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionCancelDownload(viewModels: [SessionViewModel])
    func sessionTableViewContextMenuActionRevealInFinder(viewModels: [SessionViewModel])
}

class SessionsTableViewController: NSViewController {

    fileprivate struct Metrics {
        static let headerRowHeight: CGFloat = 20
        static let sessionRowHeight: CGFloat = 64
    }

    private let disposeBag = DisposeBag()

    weak var delegate: SessionsTableViewControllerDelegate?

    var selectedSession = Variable<SessionViewModel?>(nil)

    let style: SessionsListStyle

    var searchResults: Results<Session>? {
        didSet {
            updateWithSearchResults()
        }
    }

    var sessionRowProvider: SessionRowProvider? {
        didSet {
            updateAllSessionRows()
        }
    }

    private var allRows: [SessionRow] = []

    private(set) var displayedRows: [SessionRow] = []

    lazy var displayedRowsLock: DispatchQueue = {

        return DispatchQueue(label: "io.wwdc.sessiontable.displayedrows.lock\(self.hashValue)", qos: .userInteractive)
    }()

    var hasPerformedInitialRowDisplay = false

    func setDisplayedRows(_ newValue: [SessionRow], animated: Bool) {

        if !hasPerformedInitialRowDisplay {
            hasPerformedInitialRowDisplay = true
            displayedRows = newValue
            tableView.reloadData()
            if let deferredSelection = deferredSelection {
                selectSession(with: deferredSelection.identifier, scrollOnly: deferredSelection.scrollOnly)
            }
            return
        }

        // Dismiss the menu when the displayed rows are about to change otherwise it will crash
        tableView.menu?.cancelTrackingWithoutAnimation()

        displayedRowsLock.async {

            let oldValue = self.displayedRows

            // Same elements, same order: https://github.com/apple/swift/blob/master/stdlib/public/core/Arrays.swift.gyb#L2203
            if oldValue == newValue { return }

            let oldRowsSet = Set(oldValue.enumerated().map { IndexedSessionRow(sessionRow: $1, index: $0) })
            let newRowsSet = Set(newValue.enumerated().map { IndexedSessionRow(sessionRow: $1, index: $0) })

            let removed = oldRowsSet.subtracting(newRowsSet)
            let added = newRowsSet.subtracting(oldRowsSet)

            let removedIndexes = IndexSet(removed.map { $0.index })
            let addedIndexes = IndexSet(added.map { $0.index })

            // Only reload rows if their relative positioning changes. This prevents
            // cell contents from flashing when cells are unnecessarily reloaded
            var needReloadedIndexes = IndexSet()

            let sortedOldRows = oldRowsSet.intersection(newRowsSet).sorted(by: { (row1, row2) -> Bool in
                return row1.index < row2.index
            })

            let sortedNewRows = newRowsSet.intersection(oldRowsSet).sorted(by: { (row1, row2) -> Bool in
                return row1.index < row2.index
            })

            for (oldSessionRowIndex, newSessionRowIndex) in zip(sortedOldRows, sortedNewRows) where oldSessionRowIndex.sessionRow != newSessionRowIndex.sessionRow {
                needReloadedIndexes.insert(newSessionRowIndex.index)
            }

            DispatchQueue.main.sync {

                // Preserve selected rows
                let selectedRows = self.tableView.selectedRowIndexes.flatMap { (index) -> IndexedSessionRow? in
                    guard index < oldValue.endIndex else { return nil }
                    return IndexedSessionRow(sessionRow: oldValue[index], index: index)
                }

                var selectedIndexes = IndexSet(newRowsSet.intersection(selectedRows).map { $0.index })
                if selectedIndexes.isEmpty {
                    for row in newValue {
                        if case SessionRowKind.session(_) = row.kind {
                            guard let index = newValue.index(of: row) else { continue }
                            selectedIndexes.insert(index)
                            break
                        }
                    }
                }

                NSAnimationContext.beginGrouping()
                let context = NSAnimationContext.current
                if !animated {
                    context.duration = 0
                }

                context.completionHandler = {
                    NSAnimationContext.runAnimationGroup({ (context) in
                        context.allowsImplicitAnimation = true
                        self.tableView.scrollRowToVisible(selectedIndexes.first ?? 0)
                    }, completionHandler: nil)
                }

                self.tableView.beginUpdates()

                self.tableView.removeRows(at: removedIndexes, withAnimation: [NSTableView.AnimationOptions.slideLeft])

                self.tableView.insertRows(at: addedIndexes, withAnimation: [NSTableView.AnimationOptions.slideDown])

                // insertRows(::) and removeRows(::) will query the delegate for the row count at the beginning
                // so we delay updating the data model until after those methods have done their thing
                self.displayedRows = newValue

                // This must be after you update the backing model
                self.tableView.reloadData(forRowIndexes: needReloadedIndexes, columnIndexes: IndexSet(integersIn: 0..<1))

                self.tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)

                self.tableView.endUpdates()
                NSAnimationContext.endGrouping()
            }
        }
    }

    init(style: SessionsListStyle) {
        self.style = style

        super.init(nibName: nil, bundle: nil)

        identifier = NSUserInterfaceItemIdentifier(rawValue: "videosList")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var deferredSelection: (identifier: String, scrollOnly: Bool)?

    func selectSession(with identifier: String, scrollOnly: Bool = false, deferIfNeeded: Bool = false) {

        // If we haven't yet displayed our rows, likely because we haven't come on screen
        // yet. We defer scrolling to the requested identifier until that time.
        guard hasPerformedInitialRowDisplay || !deferIfNeeded else {
            deferredSelection = (identifier, scrollOnly)
            return
        }
        guard let index = displayedRows.index(where: { row in
            guard case .session(let viewModel) = row.kind else { return false }

            return viewModel.identifier == identifier
        }) else {
            return
        }

        if !scrollOnly {
            tableView.selectRowIndexes(IndexSet([index]), byExtendingSelection: false)
        }

        tableView.scrollRowToVisible(index)
    }

    func scrollToToday() {
        if let identifier = sessionRowProvider?.sessionRowIdentifierForToday() {
            selectSession(with: identifier, scrollOnly: true)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        performFirstUpdateIfNeeded()

        searchController.searchField.isEnabled = false
        view.window?.makeFirstResponder(tableView)
        searchController.searchField.isEnabled = true
    }

    /// This function is meant to ensure the table view gets populated
    /// even if its data model gets added while it is offscreen. Specifically,
    /// when this table view is not the initial active tab.
    private func performFirstUpdateIfNeeded() {
        guard !hasPerformedInitialRowDisplay else { return }

        updateWithSearchResults()
    }

    private func updateAllSessionRows() {
        allRows = sessionRowProvider?.sessionRows() ?? []
    }

    private func updateWithSearchResults() {
        guard view.window != nil else { return }

        guard let results = searchResults else {

            if !allRows.isEmpty {
                setDisplayedRows(allRows, animated: true)
            }

            return
        }

        let sortingFunction = (style == .schedule) ? Session.standardSortForSchedule : Session.standardSort

        let sessionRows: [SessionRow] = results.sorted(by: sortingFunction).flatMap { session in
            guard let viewModel = SessionViewModel(session: session) else { return nil }

            for row in allRows {
                if case .session(let sessionViewModel) = row.kind, sessionViewModel.session.identifier == session.identifier {
                    return row
                }
            }

            return SessionRow(viewModel: viewModel)
        }

        setDisplayedRows(sessionRows, animated: true)
    }

    lazy var searchController: SearchFiltersViewController = {
        return SearchFiltersViewController.loadFromStoryboard()
    }()

    lazy var tableView: WWDCTableView = {
        let v = WWDCTableView()

        v.allowsEmptySelection = false
        v.wantsLayer = true
        v.focusRingType = .none
        v.allowsMultipleSelection = true
        v.backgroundColor = .listBackground
        v.headerView = nil
        v.rowHeight = Metrics.sessionRowHeight
        v.autoresizingMask = [.width, .height]
        v.floatsGroupRows = true
        v.gridStyleMask = .solidHorizontalGridLineMask
        v.gridColor = .darkGridColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue: "session"))
        v.addTableColumn(column)

        return v
    }()

    lazy var scrollView: NSScrollView = {
        let v = NSScrollView()

        v.focusRingType = .none
        v.backgroundColor = .listBackground
        v.borderType = .noBorder
        v.documentView = self.tableView
        v.hasVerticalScroller = true
        v.hasHorizontalScroller = false
        v.translatesAutoresizingMaskIntoConstraints = false

        return v
    }()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: MainWindowController.defaultRect.height))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.darkWindowBackground.cgColor
        view.widthAnchor.constraint(lessThanOrEqualToConstant: 675).isActive = true

        scrollView.frame = view.bounds
        tableView.frame = view.bounds

        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        view.addSubview(scrollView)
        view.addSubview(searchController.view)

        searchController.view.translatesAutoresizingMaskIntoConstraints = false

        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true

        scrollView.topAnchor.constraint(equalTo: searchController.view.bottomAnchor).isActive = true

        searchController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        searchController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        searchController.view.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self

        setupContextualMenu()

        tableView.rx.selectedRow.map { index -> SessionViewModel? in
            guard let index = index else { return nil }
            guard case .session(let viewModel) = self.displayedRows[index].kind else { return nil }

            return viewModel
            }.bind(to: selectedSession).disposed(by: disposeBag)
    }

    // MARK: - Contextual menu

    fileprivate enum ContextualMenuOption: Int {
        case watched = 1000
        case unwatched = 1001
        case favorite = 1002
        case removeFavorite = 1003
        case download = 1004
        case cancelDownload = 1005
        case revealInFinder = 1006
    }

    private func setupContextualMenu() {
        let contextualMenu = NSMenu(title: "TableView Menu")

        let watchedMenuItem = NSMenuItem(title: "Mark as Watched", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        watchedMenuItem.option = .watched
        contextualMenu.addItem(watchedMenuItem)

        let unwatchedMenuItem = NSMenuItem(title: "Mark as Unwatched", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        unwatchedMenuItem.option = .unwatched
        contextualMenu.addItem(unwatchedMenuItem)

        contextualMenu.addItem(.separator())

        let favoriteMenuItem = NSMenuItem(title: "Add to Favorites", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        favoriteMenuItem.option = .favorite
        contextualMenu.addItem(favoriteMenuItem)

        let removeFavoriteMenuItem = NSMenuItem(title: "Remove From Favorites", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        removeFavoriteMenuItem.option = .removeFavorite
        contextualMenu.addItem(removeFavoriteMenuItem)

        contextualMenu.addItem(.separator())

        let downloadMenuItem = NSMenuItem(title: "Download", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        downloadMenuItem.option = .download
        contextualMenu.addItem(downloadMenuItem)

        let cancelDownloadMenuItem = NSMenuItem(title: "Cancel Download", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        contextualMenu.addItem(cancelDownloadMenuItem)
        cancelDownloadMenuItem.option = .cancelDownload

        let revealInFinderMenuItem = NSMenuItem(title: "Reveal in Finder", action: #selector(tableViewMenuItemClicked(_:)), keyEquivalent: "")
        contextualMenu.addItem(revealInFinderMenuItem)
        revealInFinderMenuItem.option = .revealInFinder

        tableView.menu = contextualMenu
    }

    private func selectedRowIndexes() -> IndexSet {
        let clickedRow = tableView.clickedRow
        let selectedRowIndexes = tableView.selectedRowIndexes

        if clickedRow < 0 || selectedRowIndexes.contains(clickedRow) {
            return selectedRowIndexes
        } else {
            return IndexSet(integer: clickedRow)
        }
    }

    @objc private func tableViewMenuItemClicked(_ menuItem: NSMenuItem) {
        var viewModels = [SessionViewModel]()

        selectedRowIndexes().forEach { row in
            guard case .session(let viewModel) = displayedRows[row].kind else { return }

            viewModels.append(viewModel)
        }

        guard !viewModels.isEmpty else { return }

        switch menuItem.option {
        case .watched:
            delegate?.sessionTableViewContextMenuActionWatch(viewModels: viewModels)
        case .unwatched:
            delegate?.sessionTableViewContextMenuActionUnWatch(viewModels: viewModels)
        case .favorite:
            delegate?.sessionTableViewContextMenuActionFavorite(viewModels: viewModels)
        case .removeFavorite:
            delegate?.sessionTableViewContextMenuActionRemoveFavorite(viewModels: viewModels)
        case .download:
            delegate?.sessionTableViewContextMenuActionDownload(viewModels: viewModels)
        case .cancelDownload:
            delegate?.sessionTableViewContextMenuActionCancelDownload(viewModels: viewModels)
        case .revealInFinder:
            delegate?.sessionTableViewContextMenuActionRevealInFinder(viewModels: viewModels)
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        for row in selectedRowIndexes() {
            let sessionRow = displayedRows[row]

            guard case .session(let viewModel) = sessionRow.kind else { break }

            if shouldEnableMenuItem(menuItem: menuItem, viewModel: viewModel) { return true }
        }

        return false
    }

    private func shouldEnableMenuItem(menuItem: NSMenuItem, viewModel: SessionViewModel) -> Bool {

        switch menuItem.option {
        case .watched:
            return viewModel.session.progresses.first == nil || viewModel.session.progresses.first?.relativePosition != 1
        case .unwatched:
            return viewModel.session.progresses.first?.relativePosition == 1
        case .favorite:
            return !viewModel.isFavorite
        case .removeFavorite:
            return viewModel.isFavorite
        default: ()
        }

        let remoteURL = viewModel.session.assets.filter("rawAssetType == %@", SessionAssetType.hdVideo.rawValue).first?.remoteURL

        switch (menuItem.option, remoteURL) {
        case let (.download, remoteURL?):
            return !DownloadManager.shared.isDownloading(remoteURL) && DownloadManager.shared.localFileURL(for: viewModel.session) == nil
        case let (.cancelDownload, remoteURL?):
            return DownloadManager.shared.isDownloading(remoteURL)
        case let (.revealInFinder, remoteURL?):
            return DownloadManager.shared.hasVideo(remoteURL)
        default: ()
        }

        return false
    }
}

extension SessionsTableViewController: NSTableViewDataSource, NSTableViewDelegate {

    private struct Constants {
        static let sessionCellIdentifier = "sessionCell"
        static let titleCellIdentifier = "titleCell"
        static let rowIdentifier = "row"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let sessionRow = displayedRows[row]

        switch sessionRow.kind {
        case .session(let viewModel):
            return cellForSessionViewModel(viewModel)
        case .sectionHeader(let title):
            return cellForSectionTitle(title)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        var rowView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: Constants.rowIdentifier), owner: tableView) as? WWDCTableRowView

        if rowView == nil {
            rowView = WWDCTableRowView(frame: .zero)
            rowView?.identifier = NSUserInterfaceItemIdentifier(rawValue: Constants.rowIdentifier)
        }

        switch displayedRows[row].kind {
        case .sectionHeader:
            rowView?.isGroupRowStyle = true
        default:
            rowView?.isGroupRowStyle = false
        }

        return rowView
    }

    private func cellForSessionViewModel(_ viewModel: SessionViewModel) -> SessionTableCellView? {
        var cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: Constants.sessionCellIdentifier), owner: tableView) as? SessionTableCellView

        if cell == nil {
            cell = SessionTableCellView(frame: .zero)
            cell?.identifier = NSUserInterfaceItemIdentifier(rawValue: Constants.sessionCellIdentifier)
        }

        cell?.viewModel = viewModel

        return cell
    }

    private func cellForSectionTitle(_ title: String) -> TitleTableCellView? {
        var cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: Constants.titleCellIdentifier), owner: tableView) as? TitleTableCellView

        if cell == nil {
            cell = TitleTableCellView(frame: .zero)
            cell?.identifier = NSUserInterfaceItemIdentifier(rawValue: Constants.titleCellIdentifier)
        }

        cell?.title = title

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch displayedRows[row].kind {
        case .session:
            return Metrics.sessionRowHeight
        case .sectionHeader:
            return Metrics.headerRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch displayedRows[row].kind {
        case .sectionHeader:
            return false
        case .session:
            return true
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        switch displayedRows[row].kind {
        case .sectionHeader:
            return true
        case .session:
            return false
        }
    }

}

private extension NSMenuItem {

    var option: SessionsTableViewController.ContextualMenuOption {
        get {
            guard let value = SessionsTableViewController.ContextualMenuOption(rawValue: tag) else {
                fatalError("Invalid ContextualMenuOption: \(tag)")
            }

            return value
        }
        set {
            tag = newValue.rawValue
        }
    }

}
