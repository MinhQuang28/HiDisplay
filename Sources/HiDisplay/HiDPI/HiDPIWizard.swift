import HiDisplayKit
import SwiftUI

/// Generate, review, then install or export a HiDPI override — in that order, as three steps.
///
/// The earlier single-page version stacked nine sections above one Install button, and the one
/// thing a person needed to know before pressing it — *what exactly is about to change* — was in an
/// alert they only saw afterwards. The steps put the plan in front of the button: **Choose** stages
/// resolutions, **Review** shows the file that will be written, what is already there, what survives
/// and how to undo it, and **Apply** offers the two routes.
///
/// Two routes, on purpose. **Install** writes to `/Library/Displays` after one authorization prompt,
/// having first put a recovery package in Downloads. **Export Only** writes nothing outside Downloads
/// and hands back the commands, for anyone who would rather run the privileged part themselves — or
/// who is installing on a different Mac. `AppModel.planInstall` → confirmation → `performInstall`
/// is unchanged; only what is on screen around it is.
struct HiDPIWizard: View {

    enum Step: Int, CaseIterable, Identifiable {
        case choose, review, apply

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .choose: return "Choose"
            case .review: return "Review"
            case .apply: return "Apply"
            }
        }
    }

    @EnvironmentObject private var model: AppModel

    @State private var step: Step = .choose

    // Step 1: what is staged.
    @State private var chosen: Set<String> = []
    @State private var customWidth = ""
    @State private var customResolutions: [ScaledResolution] = []
    @State private var scalingIndex: Double = -1
    @State private var showFullLadder = false

    // Step 2: the plan, computed against the real override root but writing nothing. Cached so the
    // page does not re-read the file on every body evaluation; cleared whenever the selection moves.
    @State private var reviewPlan: InstallationPlan?
    @State private var reviewError: String?

    // Step 3: the install.
    /// The plan awaiting confirmation, held so the alert's Install button writes exactly what was
    /// described rather than re-planning against a file that may have changed in between.
    @State private var pendingInstall: (plan: InstallationPlan, generated: GeneratedOverride)?
    @State private var showRestartPrompt = false
    /// Whether the display just installed for can be unplugged, which decides what the apply prompt
    /// leads with. Captured at plan time because the prompt is shown after `pendingInstall` is cleared.
    @State private var installedDisplayIsExternal = false
    @State private var recoveryPackagePath: String?
    @State private var resultMessage: String?
    @State private var resultError: String?

    private var eligibleDisplays: [DisplayDevice] {
        model.displays.filter(\.capabilities.supportsHiDPIOverride)
    }

    /// The app-wide selected display when it can take an override, else the first that can. The
    /// selection is shared with the sidebar on purpose: picking a monitor there and coming here
    /// should not mean picking it again.
    private var display: DisplayDevice? {
        eligibleDisplays.first { $0.id == model.selectedDisplayID } ?? eligibleDisplays.first
    }

    /// Every aspect-correct step for the panel, the same set the scaling slider moves through.
    private var fullLadder: [ScaledResolution] {
        guard let native = display?.nativePixelSize else { return [] }
        return ResolutionPresets.scalingSteps(nativePixels: native)
    }

    private var candidates: [ScaledResolution] {
        guard let display else { return [] }
        let presetResolutions = showFullLadder
            ? fullLadder
            : ResolutionPresets
                .presets(forNativePixels: display.nativePixelSize)
                .flatMap(\.resolutions)
        // Custom entries come last and are de-duplicated against the presets, so typing a size that a
        // preset already offers does not produce two identical rows.
        var seen = Set(presetResolutions.map(\.id))
        return presetResolutions + customResolutions.filter { seen.insert($0.id).inserted }
    }

    private var selectedResolutions: [ScaledResolution] {
        candidates.filter { chosen.contains($0.id) }
    }

    private var generated: GeneratedOverride? {
        guard let display, !selectedResolutions.isEmpty else { return nil }
        let document = DisplayOverrideDocument(
            vendorID: display.identity.vendorID,
            productID: display.identity.productID,
            displayName: display.name,
            scaleResolutions: selectedResolutions)
        return OverrideGenerator.generate(document, nativePixelSize: display.nativePixelSize)
    }

    /// Whether the staged selection can go forward: something is chosen and nothing is invalid.
    private var canProceed: Bool { generated?.validation.isInstallable == true }

    var body: some View {
        Group {
            if eligibleDisplays.isEmpty {
                noEligibleDisplays
            } else {
                content
            }
        }
        .alert(
            "Install this override?",
            isPresented: Binding(
                get: { pendingInstall != nil },
                set: { if !$0 { pendingInstall = nil } })
        ) {
            Button("Install", role: .destructive) { confirmInstall() }
            Button("Cancel", role: .cancel) { pendingInstall = nil }
        } message: {
            Text(pendingInstall.map { Self.confirmationMessage(for: $0.plan) } ?? "")
        }
        // For an external display, unplugging it is the cheapest way to apply the override and the
        // only one measured to work: macOS re-reads the override file when a display attaches. It
        // costs seconds and loses nothing, so it leads. Logging out is offered because it is what
        // every guide says and because it is the only route for a built-in panel; restart stays last
        // because it buys nothing over a logout.
        .alert(installedDisplayIsExternal ? "Unplug the display to apply" : "Log out to apply?",
               isPresented: $showRestartPrompt) {
            Button("Log Out Now") { model.endSession(.logOut) }
            Button("Restart Now") { model.endSession(.restart) }
            Button(installedDisplayIsExternal ? "I'll Reconnect It" : "Later", role: .cancel) {}
        } message: {
            if installedDisplayIsExternal {
                Text("macOS re-reads display overrides when a display is attached. Unplug this monitor "
                    + "and plug it back in — that applies the change in seconds and closes nothing. "
                    + "Logging out works too; a restart is not required.")
            } else {
                Text("macOS reads display overrides when your login session starts, so logging out and "
                    + "back in is enough — a restart is not required. Your open apps will be asked to "
                    + "save either way.")
            }
        }
    }

    private var noEligibleDisplays: some View {
        ContentUnavailableView {
            Label("No display can take a HiDPI override", systemImage: "display.trianglebadge.exclamationmark")
        } description: {
            Text("An override is identified by the display's vendor and product ID, so a display that "
                + "does not report both cannot have one. Built-in displays are excluded — macOS already "
                + "manages their scaling.")
        }
    }

    // MARK: - Layout

    /// Display picker and step indicator on top, the current step in a scroll view, the actions
    /// pinned to the bottom. A primary action must never require scrolling to reach — an earlier
    /// version let the page overflow and the Install button went past the bottom edge, which made
    /// the feature look missing.
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Display", selection: Binding(
                    get: { display?.id ?? "" },
                    set: { model.selectedDisplayID = $0 })
                ) {
                    ForEach(eligibleDisplays) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 320)
                Spacer()
                StepIndicator(current: step)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            // One reset path for both ways the resolved display can change: the user picking another
            // one, and the selected display disappearing — in which case `display` silently falls
            // back to the first eligible one, and choices staged for the old panel must not carry
            // over to it.
            .onChange(of: display?.id) { _, _ in resetStagingForDisplayChange() }

            Divider()

            ScrollView {
                Group {
                    switch step {
                    case .choose: chooseStep
                    case .review: reviewStep
                    case .apply: applyStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            actionBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .onChange(of: step) { _, new in
            if new == .review { refreshReviewPlan() }
        }
        // The plan describes a particular selection; a different one needs a different plan.
        .onChange(of: chosen) { _, _ in reviewPlan = nil }
        .onChange(of: customResolutions) { _, _ in reviewPlan = nil }
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Back") {
                step = Step(rawValue: step.rawValue - 1) ?? .choose
            }
            .disabled(step == .choose)

            Spacer()

            Text(selectionSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            switch step {
            case .choose:
                Button("Review…") { step = .review }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
            case .review:
                Button("Continue") { step = .apply }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed || reviewPlan == nil)
            case .apply:
                Button("Export Only…") {
                    if let display { exportPackage(display: display, generated: generated) }
                }
                .disabled(!canProceed)
                Button("Install…") {
                    if let display { install(display: display, generated: generated) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceed)
            }
        }
    }

    private var selectionSummary: String {
        let count = selectedResolutions.count
        switch count {
        case 0: return "Nothing selected"
        case 1: return "1 resolution selected"
        default: return "\(count) resolutions selected"
        }
    }

    // MARK: - Step 1: Choose

    @ViewBuilder
    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            warningBanner
            if let display {
                scalingSlider(display)
                ladderControls(display)
                resolutionList(display)
                customEntry
                validationSection(severity: .error)
            }
        }
    }

    /// One line by default; the full warning behind a disclosure. The content is the same as before
    /// — a wrong override can mean a black screen — but five lines of orange text at the top of the
    /// page were being scrolled past, not read.
    private var warningBanner: some View {
        DisclosureGroup {
            Text("""
                A display override changes a macOS configuration file. Nothing changes until the \
                display is reattached — reconnect an external monitor, or log out for a built-in one. \
                Some monitors respond badly; a black screen after wake is the usual failure. The \
                exported package includes a verified restore script and instructions that work from \
                the macOS Recovery Terminal. Keep it until you are sure the override is good.
                """)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } label: {
            Label("Read this before installing an override", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Split out of the view body: the optional-tuple `flatMap` inline defeated SwiftUI's `ForEach`
    /// overload resolution and produced an unrelated-looking Binding error.
    private static func sharpness(
        of resolution: ScaledResolution, on display: DisplayDevice
    ) -> HiDPISharpness? {
        guard let native = display.nativePixelSize else { return nil }
        return ResolutionPresets.sharpness(of: resolution, nativePixels: native)
    }

    /// Continuous custom scaling, the way people expect it from other display tools.
    ///
    /// Every step keeps the panel's exact aspect ratio and even dimensions, so no position on the slider
    /// can produce a letterboxed or unevenly-doubled mode — the invalid options simply do not exist
    /// rather than being offered and then rejected.
    ///
    /// Note this *stages* a resolution; it does not apply one. Adding a mode that the display driver
    /// does not already publish requires a display override and a new login session. Applying an arbitrary
    /// size live, with no logout, needs private CoreGraphics APIs or a virtual display driver — both
    /// deliberately out of scope here (see docs/hidpi-overrides.md).
    @ViewBuilder
    private func scalingSlider(_ display: DisplayDevice) -> some View {
        let steps = display.nativePixelSize.map { ResolutionPresets.scalingSteps(nativePixels: $0) } ?? []
        if steps.count > 1 {
            let index = min(max(Int(scalingIndex.rounded()), 0), steps.count - 1)
            let staged = steps[index]
            let sharpness = Self.sharpness(of: staged, on: display)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Custom scaling").font(.headline)
                    Spacer()
                    Text(staged.label).font(.callout).monospacedDigit()
                }

                Slider(value: $scalingIndex, in: 0...Double(steps.count - 1), step: 1) {
                    Text("Custom scaling")
                }
                .labelsHidden()

                HStack {
                    Text("Larger text").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("More space").font(.caption).foregroundStyle(.secondary)
                }

                if let sharpness {
                    Text(sharpness.explanation)
                        .font(.caption)
                        .foregroundStyle(sharpness.isRecommended ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Add \(staged.sizeLabel) to the list") {
                    guard !candidates.contains(where: { $0.id == staged.id }) else {
                        chosen.insert(staged.id)
                        return
                    }
                    customResolutions.append(staged)
                    chosen.insert(staged.id)
                }
                .disabled(display.hasHiDPIMode(
                    width: staged.logicalWidth, height: staged.logicalHeight))
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { seedScalingIndexIfNeeded() }
        }
    }

    /// Starts the slider from whatever the display is showing now, so it opens where the user is
    /// rather than at an arbitrary end of the range. A no-op once seeded.
    private func seedScalingIndexIfNeeded() {
        guard scalingIndex < 0, let display else { return }
        let steps = display.nativePixelSize.map { ResolutionPresets.scalingSteps(nativePixels: $0) } ?? []
        guard !steps.isEmpty else { return }
        let currentWidth = display.currentMode?.width ?? steps[0].logicalWidth
        scalingIndex = Double(ResolutionPresets.nearestStepIndex(to: currentWidth, in: steps) ?? 0)
    }

    /// Clears everything staged for the previous display, goes back to the first step, and re-seeds
    /// the slider for the new one.
    private func resetStagingForDisplayChange() {
        step = .choose
        chosen = []
        customResolutions = []
        customWidth = ""
        scalingIndex = -1
        reviewPlan = nil
        reviewError = nil
        resultMessage = nil
        resultError = nil
        recoveryPackagePath = nil
        seedScalingIndexIfNeeded()
    }

    /// Bulk selection, for people who want every scaled size rather than a curated handful.
    ///
    /// Off by default: even capped at `ResolutionPresets.maximumScalingSteps`, System Settings shows
    /// every entry, which makes its resolution list unwieldy. Worth having, not worth defaulting to.
    @ViewBuilder
    private func ladderControls(_ display: DisplayDevice) -> some View {
        let usable = candidates.filter {
            !display.hasHiDPIMode(width: $0.logicalWidth, height: $0.logicalHeight)
        }
        HStack(spacing: 10) {
            Toggle("Show every step", isOn: $showFullLadder)
                .onChange(of: showFullLadder) { _, _ in chosen.removeAll() }
            Spacer()
            Button("Select all (\(usable.count))") {
                chosen.formUnion(usable.map(\.id))
            }
            .disabled(usable.isEmpty)
            Button("Clear") { chosen.removeAll() }
                .disabled(chosen.isEmpty)
        }
        .controlSize(.small)

        if showFullLadder {
            Text("Up to \(ResolutionPresets.maximumScalingSteps) aspect-correct sizes for this panel, "
                + "from 30% of native width to native. Each renders at twice its size and is scaled "
                + "down to the panel — the trade-off is GPU bandwidth, and a long list in System "
                + "Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resolutionList(_ display: DisplayDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resolutions to add").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(candidates) { resolution in
                    ResolutionRow(
                        resolution: resolution,
                        display: display,
                        isOn: Binding(
                            get: { chosen.contains(resolution.id) },
                            set: { isOn in
                                if isOn { chosen.insert(resolution.id) } else { chosen.remove(resolution.id) }
                            }))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Manual entry, locked to the panel's aspect ratio.
    ///
    /// Only a width is typed: the height is derived, and the result is snapped to the nearest size that
    /// is a whole multiple of the panel's reduced ratio. An earlier version took both numbers and merely
    /// *warned* when they did not match the panel — which meant the one place in the app that could
    /// produce a letterboxed or stretched mode was the place a person types into by hand.
    @ViewBuilder
    private var customEntry: some View {
        let native = display?.nativePixelSize
        let typedWidth = Int(customWidth)
        let match = native.flatMap { native -> ScaledResolution? in
            guard let typedWidth else { return nil }
            return ResolutionPresets.aspectCorrectResolution(forWidth: typedWidth, nativePixels: native)
        }
        let ratioLabel = native.map {
            ResolutionPresets.aspectRatioLabel(width: $0.width, height: $0.height)
        } ?? "?"

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Custom width")
                TextField("e.g. 2048", text: $customWidth).frame(width: 90)
                if let match {
                    Text("× \(match.logicalHeight)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Add") {
                    guard let match else { return }
                    if !candidates.contains(where: { $0.id == match.id }) {
                        customResolutions.append(match)
                    }
                    chosen.insert(match.id)
                    customWidth = ""
                }
                .disabled(match == nil)
            }

            if let match, let typedWidth, match.logicalWidth != typedWidth {
                Text("Snapped to \(match.sizeLabel) — the nearest size that "
                    + "keeps the panel's \(ratioLabel) shape.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Height is derived from the panel's \(ratioLabel) ratio, so a custom size can never "
                    + "be letterboxed or stretched.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Issues of one severity. Errors belong on the choose step, where they explain a disabled
    /// Review button; warnings on the review step, where they are part of what is being reviewed.
    @ViewBuilder
    private func validationSection(severity: ValidationIssue.Severity) -> some View {
        if let report = generated?.validation {
            let issues = report.issues.filter { $0.severity == severity }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues) { issue in
                        Label(issue.message, systemImage: severity == .error
                            ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(severity == .error ? Color.red : Color.orange)
                    }
                }
            }
        }
    }

    // MARK: - Step 2: Review

    @ViewBuilder
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let display, let generated {
                selectionCard(display: display)
                planCard
                validationSection(severity: .warning)
                previewSection(generated)
            } else {
                Text("Nothing is selected. Go back and choose at least one resolution.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func selectionCard(display: DisplayDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adding \(selectedResolutions.count) resolution\(selectedResolutions.count == 1 ? "" : "s") "
                + "to \(display.name)")
                .font(.headline)
            ForEach(selectedResolutions) { resolution in
                HStack {
                    Text(resolution.label)
                    Spacer()
                    if let sharpness = Self.sharpness(of: resolution, on: display) {
                        Text(sharpness.label)
                            .font(.callout)
                            .foregroundStyle(sharpness.isRecommended ? Color.secondary : Color.orange)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Every line is something the user can only act on before the write: where the file lands, what
    /// is already there, what will not survive, and how to undo it without the app. The same facts
    /// the confirmation alert states; here they can be read at leisure, before anything is committed.
    @ViewBuilder
    private var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What installing will do").font(.headline)

            if let plan = reviewPlan {
                if let action = plan.actions.last(where: { $0.kind != .createDirectory }) {
                    planRow(icon: "doc.badge.plus", title: action.kind == .replaceFile ? "Replaces" : "Creates") {
                        Text(action.absolutePath)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if action.kind == .replaceFile {
                        // The count, not just the fact. "A file is already there" reads the same
                        // whether the install keeps 242 modes or throws them away, and that ambiguity
                        // has already cost one user their whole HiDPI setup.
                        planRow(icon: "arrow.down.doc", title: "Already there") {
                            Text(plan.carriedOverEntryCount > 0
                                ? "A file with \(plan.carriedOverEntryCount) mode entries. It is copied into a "
                                    + "recovery package in Downloads first; your selection is added to it and "
                                    + "none of its entries are removed."
                                : "A file, which is copied into a recovery package in Downloads before "
                                    + "anything is replaced.")
                        }
                    }
                }
                if !plan.droppedUnknownKeys.isEmpty {
                    planRow(icon: "exclamationmark.triangle.fill", title: "Not carried over", tint: .orange) {
                        Text(plan.droppedUnknownKeys.map { "• \($0)" }.joined(separator: "\n"))
                    }
                }
                planRow(icon: "arrow.triangle.2.circlepath", title: "Takes effect") {
                    Text("After you reconnect the display, or log out and back in.")
                }
                planRow(icon: "arrow.uturn.backward", title: "Undo without this app") {
                    Text(plan.recoveryCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else if let reviewError {
                Label(reviewError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                Button("Try Again") { refreshReviewPlan() }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the current override file…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func planRow<Content: View>(
        icon: String, title: String, tint: Color = .accentColor, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                content()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Plans against the real root, writing nothing — the same call the Install button makes, so
    /// what is reviewed is what the alert will then describe.
    private func refreshReviewPlan() {
        reviewPlan = nil
        reviewError = nil
        guard let display, let generated else { return }
        do {
            reviewPlan = try model.planInstall(generated, for: display)
        } catch {
            reviewError = "Could not read the current override: \(error.localizedDescription)"
        }
    }

    private func previewSection(_ generated: GeneratedOverride) -> some View {
        DisclosureGroup("Generated file — \(generated.relativePath)") {
            if let text = String(data: generated.data, encoding: .utf8) {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 160)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 6)
            }
        }
        .font(.headline)
    }

    // MARK: - Step 3: Apply

    @ViewBuilder
    private var applyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            routeCard(
                icon: "lock.shield", title: "Install…",
                text: "Asks for your password once, backs the current override up into Downloads, "
                    + "writes the new one, and verifies it by hash. You will be shown the plan one more "
                    + "time before the password prompt.")
            routeCard(
                icon: "square.and.arrow.down", title: "Export Only…",
                text: "Writes the override and the recovery package to Downloads and prints the two "
                    + "commands to install it yourself. Nothing outside Downloads is touched, and no "
                    + "password is asked for. Use this on a different Mac, or to review the file first.")

            if resultMessage != nil || resultError != nil || model.sessionEndError != nil {
                resultCard
            }
        }
    }

    private func routeCard(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = resultMessage {
                Label {
                    Text(message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            // The recovery package is the thing to keep, so make it one click to find rather than a
            // folder name to go hunting for in Downloads.
            if let path = recoveryPackagePath {
                Button("Show Recovery Package in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
            if let error = resultError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A refused log-out or restart lands here, next to the buttons that asked for it.
            if let error = model.sessionEndError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Step one of installing: plan it and describe it. Nothing is written here.
    ///
    /// Re-planned now rather than reusing the reviewed plan: the file may have changed since the
    /// review step read it, and the alert must describe what will actually be written.
    private func install(display: DisplayDevice, generated: GeneratedOverride?) {
        resultMessage = nil
        resultError = nil
        recoveryPackagePath = nil
        guard let generated else { return }
        installedDisplayIsExternal = !display.isBuiltIn

        do {
            pendingInstall = (try model.planInstall(generated, for: display), generated)
        } catch {
            resultError = "Could not plan the install: \(error.localizedDescription)"
        }
    }

    /// What the confirmation says. Every line is something the user can only act on before the write:
    /// where it lands, what is already there, what will not survive, and how to undo it without the app.
    private static func confirmationMessage(for plan: InstallationPlan) -> String {
        var parts: [String] = []
        if let action = plan.actions.last(where: { $0.kind != .createDirectory }) {
            parts.append("Writes \(action.absolutePath)")
            if action.kind == .replaceFile {
                parts.append("A file is already there. It is copied into a recovery package in your "
                    + "Downloads folder before anything is replaced.")
                // The count, not just the fact. "A file is already there" reads the same whether the
                // install keeps 242 modes or throws them away, and that ambiguity has already cost
                // one user their whole HiDPI setup.
                if plan.carriedOverEntryCount > 0 {
                    parts.append("It holds \(plan.carriedOverEntryCount) mode entries. "
                        + "Your selection is added to them; none are removed.")
                }
            }
        }
        if !plan.droppedUnknownKeys.isEmpty {
            parts.append("Replaced by your selection, and not carried over:\n"
                + plan.droppedUnknownKeys.map { "  • \($0)" }.joined(separator: "\n"))
        }
        parts.append("Takes effect after you reconnect the display, or log out and back in. "
            + "To undo it without this app:\n" + plan.recoveryCommand)
        return parts.joined(separator: "\n\n")
    }

    /// Step two: the user has seen the plan and said yes. This is the only path that asks for a password.
    private func confirmInstall() {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil

        switch model.performInstall(pending.plan) {
        case .installed(let package, let requiresLogout):
            recoveryPackagePath = package.path
            resultMessage = """
                Installed and verified.

                A recovery package with the previous file and an undo script is in \
                \(package.lastPathComponent) in your Downloads folder.
                """
            showRestartPrompt = requiresLogout
        case .cancelled:
            resultMessage = "Cancelled — nothing was changed."
        case .failed(let message):
            resultError = message
        }
    }

    /// Writes the generated override and a recovery package into a Downloads subfolder, then reports
    /// the single command needed to install it.
    ///
    /// The plan is built against the **real** override root so the manifest and restore script contain
    /// the paths that will actually be used — but `apply` is never called here, so nothing is written
    /// outside Downloads.
    private func exportPackage(display: DisplayDevice, generated: GeneratedOverride?) {
        resultMessage = nil
        resultError = nil
        guard let generated else { return }

        do {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

            let installer = OverrideInstaller(
                root: URL(fileURLWithPath: OverridePaths.systemOverrideRoot),
                appVersion: AppModel.version)
            let plan = try installer.plan(
                generated: generated, display: display, policy: AppModel.installPolicy)

            let package = try RecoveryPackageBuilder.create(manifest: plan.manifest, in: downloads)

            // The file to install sits next to the recovery package, named exactly as it must be on
            // disk, so the install command is a plain copy with no renaming step to get wrong.
            let stagedDirectory = package.directory
                .appendingPathComponent("install", isDirectory: true)
                .appendingPathComponent(
                    OverridePaths.vendorDirectoryName(vendorID: display.identity.vendorID),
                    isDirectory: true)
            try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
            let stagedFile = stagedDirectory.appendingPathComponent(
                OverridePaths.productFileName(productID: display.identity.productID))
            try plan.payload.write(to: stagedFile, options: .atomic)

            recoveryPackagePath = package.directory.path
            resultMessage = """
                Wrote \(package.directory.lastPathComponent) to Downloads.

                To install:
                  sudo mkdir -p "\(OverridePaths.systemOverrideRoot)/\(OverridePaths.vendorDirectoryName(vendorID: display.identity.vendorID))"
                  sudo cp "\(stagedFile.path)" "\(OverridePaths.systemOverrideRoot)/\(generated.relativePath)"
                  # then unplug the display and plug it back in (or log out and back in)

                To undo: run restore.command inside that folder.
                """
            Log.hidpiGenerator.notice("exported override package for \(display.id, privacy: .public)")
        } catch {
            resultError = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// Choose → Review → Apply, with the current step highlighted and the ones behind it ticked.
private struct StepIndicator: View {

    let current: HiDPIWizard.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HiDPIWizard.Step.allCases) { step in
                HStack(spacing: 5) {
                    Image(systemName: symbol(for: step))
                    Text(step.title)
                }
                .font(step == current ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(step == current ? Color.accentColor : Color.secondary)
                .opacity(step.rawValue > current.rawValue ? 0.6 : 1)
                .accessibilityLabel(accessibilityLabel(for: step))

                if step != HiDPIWizard.Step.allCases.last {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func symbol(for step: HiDPIWizard.Step) -> String {
        if step.rawValue < current.rawValue { return "checkmark.circle.fill" }
        let number = step.rawValue + 1
        return step == current ? "\(number).circle.fill" : "\(number).circle"
    }

    private func accessibilityLabel(for step: HiDPIWizard.Step) -> String {
        let position = "Step \(step.rawValue + 1), \(step.title)"
        if step == current { return "\(position), current step" }
        return step.rawValue < current.rawValue ? "\(position), done" : position
    }
}

/// One selectable resolution.
///
/// A separate `View` rather than an inline closure: the row needs a computed sharpness value and two
/// conditional labels, and expressing that inside `ForEach`'s trailing closure pushed SwiftUI's type
/// checker onto the wrong `ForEach` overload — reported as an unrelated-looking `Binding` error.
private struct ResolutionRow: View {

    let resolution: ScaledResolution
    let display: DisplayDevice
    @Binding var isOn: Bool

    /// True when macOS already offers this size as HiDPI. Overriding it is pure risk with no benefit.
    private var alreadyExists: Bool {
        display.hasHiDPIMode(width: resolution.logicalWidth, height: resolution.logicalHeight)
    }

    private var sharpness: HiDPISharpness? {
        guard let native = display.nativePixelSize else { return nil }
        return ResolutionPresets.sharpness(of: resolution, nativePixels: native)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Text(resolution.label)
                if alreadyExists {
                    Text("already available").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // "HiDPI" alone does not say how sharp a mode will actually be — the backing store's
                // relationship to the panel's real pixels does.
                if let sharpness {
                    Text(sharpness.label)
                        .font(.caption)
                        .foregroundStyle(sharpness.isRecommended ? Color.secondary : Color.orange)
                }
            }
        }
        .disabled(alreadyExists)
        .help(sharpness?.explanation ?? "")
    }
}
