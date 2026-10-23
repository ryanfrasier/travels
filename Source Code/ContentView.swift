import SwiftUI
import MapKit

struct VisitedPlace: Identifiable, Codable, Hashable {
    var id: String { "\(kind):\(name)" }
    let name: String
    let kind: String
    let addedAt: Date
}

struct PlaceOption: Identifiable, Hashable {
    var id: String { "\(kind):\(name)" }
    let name: String
    let kind: String
}

@MainActor
final class TravelStore: ObservableObject {
    @Published var visited: [VisitedPlace] = [] {
        didSet { save() }
    }
    @Published var polygons: [String: [MKPolygon]] = [:]
    @Published var loading = true
    @Published var mapError: String?

    private let savedKey = "travels.visited.v1"
    private let countryURL = "https://raw.githubusercontent.com/datasets/geo-countries/master/data/countries.geojson"
    private let stateURL = "https://raw.githubusercontent.com/PublicaMundi/MappingAPI/master/data/geojson/us-states.json"

    let states = "Alabama|Alaska|Arizona|Arkansas|California|Colorado|Connecticut|Delaware|Florida|Georgia|Hawaii|Idaho|Illinois|Indiana|Iowa|Kansas|Kentucky|Louisiana|Maine|Maryland|Massachusetts|Michigan|Minnesota|Mississippi|Missouri|Montana|Nebraska|Nevada|New Hampshire|New Jersey|New Mexico|New York|North Carolina|North Dakota|Ohio|Oklahoma|Oregon|Pennsylvania|Rhode Island|South Carolina|South Dakota|Tennessee|Texas|Utah|Vermont|Virginia|Washington|West Virginia|Wisconsin|Wyoming".components(separatedBy: "|")

    var options: [PlaceOption] {
        let countries = Locale.isoRegionCodes.compactMap { code -> String? in
            guard let name = Locale(identifier: "en_US").localizedString(forRegionCode: code),
                  name != code else { return nil }
            return name
        }
        return (countries.map { PlaceOption(name: $0, kind: "Country") } +
                states.map { PlaceOption(name: $0, kind: "State") })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: savedKey),
           let stored = try? JSONDecoder().decode([VisitedPlace].self, from: data) {
            visited = stored
        }
    }

    func add(_ option: PlaceOption) {
        guard !visited.contains(where: { $0.id == option.id }) else { return }
        visited.append(VisitedPlace(name: option.name, kind: option.kind, addedAt: Date()))
    }

    func remove(_ place: VisitedPlace) {
        visited.removeAll { $0.id == place.id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(visited) else { return }
        UserDefaults.standard.set(data, forKey: savedKey)
    }

    private enum BorderError: Error { case invalidFeatures }

    func loadBorders() async {
        loading = true
        mapError = nil
        var combined: [String: [MKPolygon]] = [:]
        var failures: [String] = []
        for (kind, urlString) in [("Country", countryURL), ("State", stateURL)] {
            do {
                guard let url = URL(string: urlString) else { continue }
                let data: Data
                let localName = kind == "Country" ? "countries" : "us-states"
                if let localURL = Bundle.main.url(forResource: localName, withExtension: "geojson") {
                    data = try Data(contentsOf: localURL)
                } else {
                    let (download, response) = try await URLSession.shared.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    data = download
                }
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let features = json?["features"] as? [[String: Any]] ?? []
                // Decode the entire FeatureCollection once. Decoding individual
                // feature dictionaries is not supported reliably by MapKit.
                let decoded = try MKGeoJSONDecoder().decode(data)
                let geoFeatures = decoded.compactMap { $0 as? MKGeoJSONFeature }
                guard !features.isEmpty, features.count == geoFeatures.count else {
                    throw BorderError.invalidFeatures
                }
                for (feature, geoFeature) in zip(features, geoFeatures) {
                    let props = feature["properties"] as? [String: Any] ?? [:]
                    let name = (kind == "Country"
                                ? (props["ADMIN"] as? String ?? props["name"] as? String)
                                : (props["name"] as? String)) ?? ""
                    guard !name.isEmpty else { continue }
                    let polygons = geoFeature.geometry.flatMap { shape -> [MKPolygon] in
                        if let polygon = shape as? MKPolygon { return [polygon] }
                        if let multi = shape as? MKMultiPolygon { return multi.polygons }
                        return []
                    }
                    combined["\(kind):\(normalized(name))", default: []].append(contentsOf: polygons)
                }
            } catch {
                failures.append(kind.lowercased() + " borders")
            }
        }
        polygons = combined
        if !failures.isEmpty {
            mapError = "Couldn't load \(failures.joined(separator: " and ")). Add the GeoJSON files to the app, or check the download connection."
        }
        loading = false
    }

    func shapes(for place: VisitedPlace) -> [MKPolygon] {
        let aliases: [String: String] = [
            "united states": "united states of america",
            "czechia": "czech republic",
            "turkiye": "turkey",
            "south korea": "south korea",
            "north korea": "north korea"
        ]
        let key = normalized(place.name)
        return polygons["\(place.kind):\(key)"] ??
               polygons["\(place.kind):\(aliases[key] ?? key)"] ?? []
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TravelMap: UIViewRepresentable {
    let highlighted: [MKPolygon]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .standard
        map.showsCompass = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 18, longitude: 0),
                                         span: MKCoordinateSpan(latitudeDelta: 130, longitudeDelta: 170)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.addOverlays(highlighted)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.34)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

struct ContentView: View {
    @StateObject private var store = TravelStore()
    @State private var search = ""
    @State private var showHistory = false
    @FocusState private var searchFocused: Bool

    private var matches: [PlaceOption] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return Array(store.options.filter { $0.name.localizedStandardContains(search) }.prefix(12))
    }

    private var highlighted: [MKPolygon] {
        store.visited.flatMap { store.shapes(for: $0) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            TravelMap(highlighted: highlighted)
                .ignoresSafeArea(edges: .bottom)
                .onTapGesture { searchFocused = false }

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search countries or U.S. states", text: $search)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    Button { searchFocused = false; showHistory = true } label: {
                        Image(systemName: "list.bullet")
                            .font(.title3)
                    }
                    .accessibilityLabel("Visited places")
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))

                if !matches.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { option in
                                Button {
                                    store.add(option)
                                    search = ""
                                    searchFocused = false
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(option.name).foregroundStyle(.primary)
                                            Text(option.kind).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: store.visited.contains(where: { $0.id == option.id }) ? "checkmark.circle.fill" : "plus.circle")
                                    }
                                    .padding(12)
                                }
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
                }

                if store.loading {
                    Label("Loading map borders…", systemImage: "globe")
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                } else if let error = store.mapError {
                    Text(error)
                        .font(.caption)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
        .task { await store.loadBorders() }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                List {
                    if store.visited.isEmpty {
                        ContentUnavailableView("No places yet", systemImage: "globe", description: Text("Search for a country or state and tap it to add it."))
                    } else {
                        ForEach(store.visited.sorted { $0.addedAt < $1.addedAt }) { place in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(place.name).font(.headline)
                                    Text(place.kind).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(place.addedAt, format: .dateTime.month(.abbreviated).day().year())
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(role: .destructive) { store.remove(place) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .navigationTitle("Visited Places")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showHistory = false } } }
            }
        }
    }
}
