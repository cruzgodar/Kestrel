import CoreLocation
import MapKit
import SwiftUI

struct MapView: View {
    @State private var position: MapCameraPosition = .userLocation(
        fallback: .automatic
    )
    @State private var locationAuth = CLLocationManager().authorizationStatus

    var body: some View {
        Map(position: $position) {
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea(edges: .bottom)
        .task {
            // Nudge the permission prompt if the user hits Map before ever
            // tapping Start Recording. Once granted, the .userLocation
            // camera position resolves and the blue dot appears.
            let manager = CLLocationManager()
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            locationAuth = manager.authorizationStatus
        }
    }
}

#Preview {
    MapView()
}
