import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_client.dart';
import 'contribution_stats.dart';
import 'theme.dart';

/// The rider's own page: what they contributed, and the optional account.
/// No feed status, no preferences, no About section.
class YouScreen extends ConsumerWidget {
  const YouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(contributionStatsProvider);
    final user = ref.watch(authControllerProvider).value;

    return Scaffold(
      backgroundColor: WimbColors.cream,
      appBar: AppBar(title: const Text('You')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(
            'Your rides, quietly counted.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'These numbers stay on this phone. No account is required.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  value: '${stats.updates}',
                  label: 'position updates',
                  icon: Icons.people_alt_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _MetricCard(
                  value: '${stats.rides}',
                  label: 'rides tracked',
                  icon: Icons.directions_bus_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          const SectionLabel('Account'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: user == null
                  ? Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Using the app without an account.',
                            style: TextStyle(fontSize: 13.5),
                          ),
                        ),
                        TextButton(
                          onPressed: () => ref
                              .read(authControllerProvider.notifier)
                              .showSignIn(),
                          child: const Text('Sign in'),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: WimbColors.dtcRed.withValues(
                            alpha: 0.12,
                          ),
                          child: Text(
                            user.displayName.isEmpty
                                ? '?'
                                : user.displayName
                                      .substring(0, 1)
                                      .toUpperCase(),
                            style: const TextStyle(
                              color: WimbColors.dtcRed,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                user.email,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => ref
                              .read(authControllerProvider.notifier)
                              .signOut(),
                          child: const Text('Sign out'),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;

  const _MetricCard({
    required this.value,
    required this.label,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: WimbColors.inkMuted),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(
                fontFamily: WimbFonts.condensed,
                fontSize: 34,
                height: 1,
                fontWeight: FontWeight.w700,
                fontFeatures: WimbFonts.tabular,
              ),
            ),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
