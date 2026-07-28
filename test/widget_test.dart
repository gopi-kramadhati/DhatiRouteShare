// Unit tests for RouteShare.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:route_share_app/main.dart';

void main() {
  test('RouteWaypoint serializes and deserializes', () {
    const wp = RouteWaypoint(LatLng(12.97160, 77.59460), 'Start');
    final restored = RouteWaypoint.fromJson(wp.toJson());

    expect(restored.position.latitude, closeTo(12.97160, 1e-9));
    expect(restored.position.longitude, closeTo(77.59460, 1e-9));
    expect(restored.label, 'Start');
  });

  test('RouteWaypoint tolerates a missing label', () {
    final wp = RouteWaypoint.fromJson({'lat': 1.0, 'lng': 2.0});
    expect(wp.label, '');
    expect(wp.position.latitude, 1.0);
    expect(wp.position.longitude, 2.0);
  });
}
