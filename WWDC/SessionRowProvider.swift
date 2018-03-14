//
//  SessionRowProvider.swift
//  WWDC
//
//  Created by Allen Humphreys on 3/14/18.
//  Copyright © 2018 Guilherme Rambo. All rights reserved.
//

import ConfCore
import RealmSwift

protocol SessionRowProvider {
    func sessionRowIdentifierForToday() -> String?
    func sessionRows() -> [SessionRow]
}

struct VideosSessionRowProvider: SessionRowProvider {

    var tracks: Results<Track>

    func sessionRows() -> [SessionRow] {

        let rows: [SessionRow] = tracks.flatMap { track -> [SessionRow] in
            let titleRow = SessionRow(title: track.name)

            let sessionRows: [SessionRow] = track.sessions.filter(Session.videoPredicate).sorted(by: Session.standardSort).flatMap { session in
                guard let viewModel = SessionViewModel(session: session) else { return nil }

                return SessionRow(viewModel: viewModel)
            }

            return [titleRow] + sessionRows
        }

        return rows
    }

    func sessionRowIdentifierForToday() -> String? {
        return nil
    }
}

struct ScheduleSessionRowProvider: SessionRowProvider {

    var scheduleSections: Results<ScheduleSection>

    func sessionRows() -> [SessionRow] {

        // Only show the timezone on the first section header
        var shownTimeZone = false

        let rows: [SessionRow] = scheduleSections.flatMap { section -> [SessionRow] in

            // Section header
            let titleRow = SessionRow(date: section.representedDate, showTimeZone: !shownTimeZone)

            shownTimeZone = true

            let instanceRows: [SessionRow] = section.instances.sorted(by: SessionInstance.standardSort).flatMap { instance in
                guard let viewModel = SessionViewModel(session: instance.session, instance: instance, style: .schedule) else { return nil }

                return SessionRow(viewModel: viewModel)
            }

            return [titleRow] + instanceRows
        }

        return rows
    }

    func sessionRowIdentifierForToday() -> String? {

        guard let section = scheduleSections.filter("representedDate >= %@", today()).first else { return nil }

        guard let identifier = section.instances.first?.session?.identifier else { return nil }

        return identifier
    }
}
