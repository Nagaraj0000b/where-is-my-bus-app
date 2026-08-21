// The landing screen.
//
// WHY THIS EXISTS
//
// The app used to open straight onto the journey planner's From/To boxes.
// That works, but it says nothing: it looks like a form, it gives no sense
// of what the app knows or how far to trust it, and it makes the honesty
// idea - the whole point of the project - something you only discover
// after you have already asked a question.
//
// This screen leads with that instead. It greets you, offers the three
// things the app can do, and then shows what those answers are actually
// built on, counted live from the database rather than claimed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'auth_client.dart';
import 'error_card.dart';
import 'theme.dart';

/// Loaded once and cached for the life of the app. These numbers change
/// only when the database is rebuilt, so re-fetching on every visit to the
/// home tab would be pointless traffic.
final statsProvider = FutureProvider<ProjectStats>((ref) => fetchStats());

/// Which tab to jump to when a quick-action card is tapped. main.dart owns
/// the actual tab index; this is how a card asks it to change.
typedef TabRequest = void Function(int tabIndex);

class HomeScreen extends ConsumerWidget {
  final TabRequest onOpenTab;
  const HomeScreen({super.key, required this.onOpenTab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).value;

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _RedHeader(user: user),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('What do you need?'),
                _ActionCard(
                  icon: Icons.alt_route,
                  title: 'Plan a journey',
                  description: 'Two places in, ranked ways to travel out - '
                      'walk, wait and ride all counted.',
                  onTap: () => onOpenTab(1),
                ),
                const SizedBox(height: 10),
                _ActionCard(
                  icon: Icons.schedule,
                  title: 'When should I travel?',
                  description: 'The same trip costed for every hour, so you '
                      'can see if leaving later is faster.',
                  onTap: () => onOpenTab(2),
                ),
                const SizedBox(height: 10),
                _ActionCard(
                  icon: Icons.directions_bus_filled,
                  title: 'Browse routes',
                  description: 'Every stop a route calls at, in order - and '
                      'the time between any two of them.',
                  onTap: () => onOpenTab(3),
                ),
                const SizedBox(height: 26),
                const SectionLabel('What this is built on'),
                _StatsPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The red band at the top: wordmark, greeting, and the app's one-line
/// promise. Full-bleed to the top of the screen, under the status bar.
class _RedHeader extends ConsumerWidget {
  final AuthUser? user;
  const _RedHeader({required this.user});

  /// The account sheet. Slides up from the bottom rather than opening a
  /// whole screen, because there is very little in it - who you are, and
  /// the way out.
  void _showAccountSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WimbColors.cardCream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel('Account'),
              if (user == null) ...[
                Text(
                  "You're using the app without an account.",
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Everything here works as it is. An account only adds saved '
                  'places and lets you report a bus the feed has missed.',
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    // Dropping the "I skipped sign-in" flag sends the app
                    // back through AuthGate, which then shows the sign-in
                    // screen again.
                    ref.read(authControllerProvider.notifier).showSignIn();
                  },
                  child: const Text('Sign in or create an account'),
                ),
              ] else ...[
                Text(user!.displayName, style: Theme.of(sheetContext).textTheme.titleLarge),
                Text(user!.email, style: Theme.of(sheetContext).textTheme.bodySmall),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    ref.read(authControllerProvider.notifier).signOut();
                  },
                  icon: const Icon(Icons.logout, size: 18),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: WimbColors.dtcRed,
                    minimumSize: const Size.fromHeight(48),
                    side: const BorderSide(color: WimbColors.hairline),
                  ),
                  label: const Text('Sign out'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: double.infinity,
      color: WimbColors.dtcRed,
      padding: EdgeInsets.fromLTRB(
        18,
        // Clears the status bar without hardcoding a guess at its height.
        MediaQuery.of(context).padding.top + 18,
        18,
        20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(child: WimbWordmark()),
              // Initials when signed in, a plain outline when not - so the
              // header itself shows at a glance which you are.
              InkWell(
                onTap: () => _showAccountSheet(context, ref),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: user == null ? 0.0 : 0.18),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
                  ),
                  child: user == null
                      ? const Icon(Icons.person_outline, color: Colors.white, size: 20)
                      : Center(
                          child: Text(
                            user!.firstName.characters.first.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            user == null ? 'Where are you headed?' : 'Hello, ${user!.firstName}.',
            style: const TextStyle(
              fontFamily: WimbFonts.condensed,
              fontFamilyFallback: WimbFonts.fallback,
              color: Colors.white,
              fontSize: 27,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Every time comes with a range and how much to trust it.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13.5),
          ),
        ],
      ),
    );
  }
}

/// One of the three big tappable things this app can do.
class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      // InkWell inside the Card (rather than wrapping it) so the ripple is
      // clipped to the card's rounded corners instead of spilling square.
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: WimbColors.dtcRed.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: WimbColors.dtcRed, size: 23),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(description, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: WimbColors.inkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// The accountability panel: how much real data is behind the answers, and
/// how wrong they are known to be.
///
/// The measured error is shown as prominently as the good numbers on
/// purpose. CLAUDE.md's sixth difference from the official app is "we
/// measure our own error and publish the number" - hiding it in a settings
/// screen would make that a slogan rather than a practice.
class _StatsPanel extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider);

    return stats.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (err, _) => ErrorCard(
        message: err.toString(),
        onRetry: () => ref.invalidate(statsProvider),
      ),
      data: (s) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: _Stat(value: _short(s.stopPassages), label: 'bus arrivals\nrecorded')),
                  Expanded(child: _Stat(value: '${s.daysRecorded}', label: 'days of real\ntraffic')),
                  Expanded(child: _Stat(value: _short(s.routes), label: 'routes\ncovered')),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(),
              const SizedBox(height: 12),

              // The measured error, stated plainly.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.straighten, size: 17, color: WimbColors.delhiGreen),
                  const SizedBox(width: 9),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: Theme.of(context).textTheme.bodySmall,
                        children: [
                          const TextSpan(
                            text: 'We measured our own error. ',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: WimbColors.delhiGreen,
                            ),
                          ),
                          TextSpan(
                            text: 'On a 20-stop journey this app is typically about '
                                '${(s.weekdayErrorSeconds / 60).round()} minutes out, '
                                'tested by holding back each recorded day in turn '
                                'and predicting it from the other six.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),
              ...s.honesty.map((line) => CaveatLine(line)),
            ],
          ),
        ),
      ),
    );
  }

  /// 9,731,332 -> "9.7M". Full precision is meaningless at a glance, and
  /// a seven-digit number in a small box just reads as noise.
  static String _short(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

/// One big number with its caption, inside the stats panel.
class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontFamily: WimbFonts.condensed,
            fontFamilyFallback: WimbFonts.fallback,
            fontSize: 27,
            fontWeight: FontWeight.w700,
            color: WimbColors.dtcRed,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: WimbColors.inkMuted, height: 1.25),
        ),
      ],
    );
  }
}
