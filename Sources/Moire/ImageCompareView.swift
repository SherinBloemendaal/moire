import MoireKit
import SwiftUI

@Observable
final class ImageModel {
    enum Mode: String, CaseIterable {
        case sideBySide
        case overlay
        case swipe
        case difference

        var title: String {
            switch self {
            case .sideBySide: "Side by Side"
            case .overlay: "Overlay"
            case .swipe: "Swipe"
            case .difference: "Difference"
            }
        }
    }

    var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "imageMode") ?? "") ?? .sideBySide {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "imageMode") }
    }
    /// How much of the right image shows over the left one.
    var opacity = 0.5
    /// Where the swipe line is, from 0 (all right image) to 1 (all left image).
    var swipe = 0.5
    var tolerance = UserDefaults.standard.integer(forKey: "imageTolerance") {
        didSet { UserDefaults.standard.set(tolerance, forKey: "imageTolerance") }
    }

    private(set) var left: LoadedImage?
    private(set) var right: LoadedImage?
    private(set) var leftError: String?
    private(set) var rightError: String?
    private(set) var difference: PixelDifference?
    private(set) var mask: CGImage?
    private(set) var sameBytes = false
    private(set) var isComparing = false

    func load(_ leftURL: URL?, _ rightURL: URL?) async {
        left = nil
        right = nil
        difference = nil
        mask = nil
        isComparing = true
        async let leftImage = Self.load(leftURL)
        async let rightImage = Self.load(rightURL)
        let (a, b) = await (leftImage, rightImage)
        guard !Task.isCancelled else { return }
        (left, leftError) = Self.split(a)
        (right, rightError) = Self.split(b)

        if let leftURL, let rightURL {
            sameBytes = (try? await runDetached {
                FileManager.default.contentsEqual(atPath: leftURL.path(percentEncoded: false), andPath: rightURL.path(percentEncoded: false))
            }) ?? false
        } else {
            sameBytes = false
        }
        if let left, let right {
            let difference = try? await runDetached { try PixelDifference(left: left.image, right: right.image) }
            guard !Task.isCancelled else { return }
            self.difference = difference
        }
        isComparing = false
        await updateMask()
    }

    func updateMask() async {
        guard let difference else {
            mask = nil
            return
        }
        let tolerance = tolerance
        let result = try? await runDetached { difference.mask(tolerance: tolerance).map(SendableImage.init) }
        guard !Task.isCancelled else { return }
        mask = result?.image
    }

    private static func load(_ url: URL?) async -> Result<LoadedImage, Error>? {
        guard let url else { return nil }
        do {
            return .success(try await runDetached { try LoadedImage.load(url) })
        } catch {
            return .failure(error)
        }
    }

    private static func split(_ result: Result<LoadedImage, Error>?) -> (LoadedImage?, String?) {
        switch result {
        case .success(let image)?: (image, nil)
        case .failure(let error)?: (nil, error.localizedDescription)
        case nil: (nil, nil)
        }
    }
}

private struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

struct ImageCompareView: View {
    let compare: CompareModel
    @State private var model = ImageModel()

    var body: some View {
        let files = compare.fileView
        KindLayout {
            VStack(spacing: 0) {
                infoRow
                Rectangle().fill(Theme.paneBorder).frame(height: 1)
                canvas
                    .padding(14)
            }
        } bar: {
            verdict
            Spacer()
            modeControls
            Picker("Mode", selection: $model.mode) {
                ForEach(ImageModel.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .task(id: files.revision) {
            await model.load(compare.left.url, compare.right.url)
        }
        .task(id: model.tolerance) {
            await model.updateMask()
        }
        .onAppear { files.navigator = nil }
    }

    // MARK: Parts

    private var infoRow: some View {
        HStack(spacing: 0) {
            info(model.left, error: model.leftError, color: Theme.removed)
            Rectangle().fill(Theme.paneBorder).frame(width: 1)
            info(model.right, error: model.rightError, color: Theme.added)
        }
        .frame(height: 34)
    }

    private func info(_ image: LoadedImage?, error: String?, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            if let image {
                Text("\(image.width) × \(image.height)").fontWeight(.semibold).monospacedDigit()
                Text(details(image)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            } else if let error {
                Text(error).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(model.isComparing ? "Loading…" : "No image").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private func details(_ image: LoadedImage) -> String {
        var parts = [image.colorSpaceName, "\(image.bitsPerComponent)-bit"]
        if image.hasAlpha { parts.append("alpha") }
        if let type = image.typeIdentifier { parts.append(type.replacingOccurrences(of: "public.", with: "").uppercased()) }
        parts.append(image.fileSize.fileSizeText)
        if image.frameCount > 1 { parts.append("first of \(image.frameCount) images") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var canvas: some View {
        if model.left == nil, model.right == nil {
            if model.isComparing {
                KindMessage(systemImage: "photo", title: "Loading images…", isWorking: true)
            } else {
                KindMessage(systemImage: "photo", title: "No image to show", message: model.leftError ?? model.rightError)
            }
        } else {
            switch model.mode {
            case .sideBySide:
                HStack(spacing: 14) {
                    ImageCanvas(images: [model.left?.image], size: size(of: model.left))
                    ImageCanvas(images: [model.right?.image], size: size(of: model.right))
                }
            case .overlay:
                ImageCanvas(images: [model.left?.image, model.right?.image], size: commonSize, opacities: [1, model.opacity])
            case .swipe:
                SwipeCanvas(left: model.left?.image, right: model.right?.image, size: commonSize, position: $model.swipe)
            case .difference:
                if model.difference != nil {
                    ImageCanvas(images: [model.left?.image, model.mask], size: commonSize, opacities: [0.25, 1], grayscaleFirst: true)
                } else {
                    KindMessage(systemImage: "square.on.square", title: "Needs two images", message: "The difference mask compares the pixels of both sides.")
                }
            }
        }
    }

    private func size(of image: LoadedImage?) -> CGSize {
        CGSize(width: image?.width ?? 1, height: image?.height ?? 1)
    }

    private var commonSize: CGSize {
        CGSize(width: max(model.left?.width ?? 1, model.right?.width ?? 1), height: max(model.left?.height ?? 1, model.right?.height ?? 1))
    }

    @ViewBuilder
    private var modeControls: some View {
        switch model.mode {
        case .overlay:
            Text("Right")
            Slider(value: $model.opacity, in: 0...1).frame(width: 140)
                .help("How much of the right image shows over the left one")
        case .swipe:
            Text("Drag the line, or").foregroundStyle(.secondary)
            Slider(value: $model.swipe, in: 0...1).frame(width: 120)
        case .difference:
            Text("Tolerance")
            Slider(value: Binding(get: { Double(model.tolerance) }, set: { model.tolerance = Int($0.rounded()) }), in: 0...255)
                .frame(width: 140)
                .help("Pixels whose red, green, blue or alpha value differs by this much or less count as the same (0 to 255)")
            Text("\(model.tolerance)").monospacedDigit().frame(minWidth: 26, alignment: .trailing)
        case .sideBySide:
            EmptyView()
        }
    }

    @ViewBuilder
    private var verdict: some View {
        if model.isComparing {
            ProgressView().controlSize(.mini)
        } else if model.sameBytes {
            Chip(text: "Identical files", color: Theme.iris, systemImage: "checkmark")
        } else if let difference = model.difference {
            if difference.isIdentical {
                Chip(text: "Identical pixels", color: Theme.iris, systemImage: "checkmark")
                Text("The files differ, but they decode to the same pixels.").foregroundStyle(.secondary).lineLimit(1)
            } else {
                let count = difference.differingPixels(tolerance: model.tolerance)
                let share = Double(count) / Double(max(difference.pixelCount, 1))
                if count == 0 {
                    Chip(text: "Same within tolerance", color: Theme.iris, systemImage: "checkmark")
                } else {
                    Chip(text: "\(count.formatted()) pixels differ", color: Theme.changed)
                    Text(share.formatted(.percent.precision(.fractionLength(0...2)))).foregroundStyle(.secondary).monospacedDigit()
                }
                if !difference.sameDimensions {
                    Text("Sizes differ: compared from the top left corner").foregroundStyle(.secondary).lineLimit(1)
                }
                if let left = model.left, let right = model.right, left.orientation != right.orientation {
                    Text("Orientation tags differ: pixels are compared as stored").foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Images drawn on top of each other at one scale that fits `size` into the space, all from
/// the top left corner, so pixels of different images line up.
private struct ImageCanvas: View {
    var images: [CGImage?]
    var size: CGSize
    var opacities: [Double] = []
    var grayscaleFirst = false

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height, 8)
            ZStack(alignment: .topLeading) {
                Checkerboard()
                ForEach(images.indices, id: \.self) { index in
                    if let image = images[index] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(scale > 2 ? .none : .high)
                            .frame(width: Double(image.width) * scale, height: Double(image.height) * scale)
                            .grayscale(grayscaleFirst && index == 0 ? 1 : 0)
                            .opacity(index < opacities.count ? opacities[index] : 1)
                    }
                }
            }
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The left image on the left of a line you can drag, the right image on the right of it.
private struct SwipeCanvas: View {
    var left: CGImage?
    var right: CGImage?
    var size: CGSize
    @Binding var position: Double

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height, 8)
            let width = size.width * scale
            let height = size.height * scale
            ZStack(alignment: .topLeading) {
                Checkerboard()
                image(right, scale: scale)
                image(left, scale: scale)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: width * position, height: height)
                    }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: width * position - 1)
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                position = min(max(value.location.x / max(width, 1), 0), 1)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func image(_ image: CGImage?, scale: Double) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(scale > 2 ? .none : .high)
                .frame(width: Double(image.width) * scale, height: Double(image.height) * scale)
        }
    }
}

/// The usual grey checks behind transparent pixels.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell = 8.0
            var path = Path()
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: Double(column) * cell, y: Double(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(Theme.subtleFill))
        }
    }
}
