//
//  PromptCoordinator.swift
//  Reynard
//
//  Created by Minh Ton on 16/6/26.
//

import GeckoView

@MainActor
protocol PromptPresenting {
    func present(_ request: PromptRequest, for session: GeckoSession) async -> PromptResponse?
    func update(_ request: PromptRequest)
    func dismiss(promptID: String)
}

@MainActor
final class PromptCoordinator: PromptDelegate {
    private let presenter: PromptPresenting
    private let onPromptFinished: ((GeckoSession) -> Void)?
    /// ADDED - see fix_prompts_wait_for_selected_tab.py. Whether a
    /// session is the one in front: true presents now, false waits, nil
    /// means the session is not a tab any more and the prompt is
    /// dropped. A nil CLOSURE (the add-on popup's coordinator) presents
    /// everything at once, as before.
    private let isSessionInFront: ((GeckoSession) -> Bool?)?
    /// Prompt ids waiting for their tab, and the ones Gecko dismissed
    /// while they waited.
    private var waitingPromptIDs: Set<String> = []
    private var dismissedWhileWaiting: Set<String> = []
    
    init(
        presenter: PromptPresenting,
        onPromptFinished: ((GeckoSession) -> Void)? = nil,
        isSessionInFront: ((GeckoSession) -> Bool?)? = nil
    ) {
        self.presenter = presenter
        self.onPromptFinished = onPromptFinished
        self.isSessionInFront = isSessionInFront
    }
    
    func onPrompt(session: GeckoSession, request: PromptRequest) async -> PromptResponse? {
        // WAIT FOR THE TAB - see fix_prompts_wait_for_selected_tab.py.
        // Every session shares this coordinator and the presenter puts
        // the sheet on whatever is on top, so a background tab's alert()
        // or auth prompt used to land over the page the user was
        // reading, titled with the other tab's host. It now waits until
        // that tab is selected - which is exactly what the tab's own
        // script is already doing, waiting on the answer.
        guard await waitUntilInFront(session, promptID: request.id) else {
            return nil
        }
        let response = await presenter.present(request, for: session)
        onPromptFinished?(session)
        return response
    }
    
    /// True once the session is in front; false if Gecko dismissed the
    /// prompt meanwhile, the task was cancelled, or the session stopped
    /// being a tab.
    private func waitUntilInFront(_ session: GeckoSession, promptID: String) async -> Bool {
        guard let isSessionInFront else {
            return true
        }
        guard let inFront = isSessionInFront(session) else {
            return false
        }
        if inFront {
            return true
        }
        waitingPromptIDs.insert(promptID)
        defer {
            waitingPromptIDs.remove(promptID)
            dismissedWhileWaiting.remove(promptID)
        }
        while true {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled || dismissedWhileWaiting.contains(promptID) {
                return false
            }
            guard let inFrontNow = isSessionInFront(session) else {
                return false
            }
            if inFrontNow {
                return true
            }
        }
    }
    
    func onPromptUpdate(session: GeckoSession, request: PromptRequest) {
        presenter.update(request)
    }
    
    func onPromptDismiss(session: GeckoSession, promptId: String) {
        // A prompt still waiting for its tab has nothing presented to
        // dismiss; the wait itself ends instead. See
        // fix_prompts_wait_for_selected_tab.py.
        if waitingPromptIDs.contains(promptId) {
            dismissedWhileWaiting.insert(promptId)
        }
        presenter.dismiss(promptID: promptId)
    }
}
