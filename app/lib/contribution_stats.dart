import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local counters for the rider's own contribution. No server account is
/// required; the numbers stay on the phone.
class ContributionStats {
  final int updates;
  final int rides;

  const ContributionStats({this.updates = 0, this.rides = 0});

  ContributionStats copyWith({int? updates, int? rides}) => ContributionStats(
    updates: updates ?? this.updates,
    rides: rides ?? this.rides,
  );
}

class ContributionStatsController extends StateNotifier<ContributionStats> {
  ContributionStatsController() : super(const ContributionStats()) {
    _load();
  }

  static const _updatesKey = 'wimb_contribution_updates_v1';
  static const _ridesKey = 'wimb_contribution_rides_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ContributionStats(
      updates: prefs.getInt(_updatesKey) ?? 0,
      rides: prefs.getInt(_ridesKey) ?? 0,
    );
  }

  Future<void> recordUpdate() async {
    state = state.copyWith(updates: state.updates + 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_updatesKey, state.updates);
  }

  Future<void> recordRide() async {
    state = state.copyWith(rides: state.rides + 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_ridesKey, state.rides);
  }

  Future<void> reset() async {
    state = const ContributionStats();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_updatesKey);
    await prefs.remove(_ridesKey);
  }
}

final contributionStatsProvider =
    StateNotifierProvider<ContributionStatsController, ContributionStats>((
      ref,
    ) {
      return ContributionStatsController();
    });
