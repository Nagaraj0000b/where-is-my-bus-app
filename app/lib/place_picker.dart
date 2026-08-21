// Choosing a place, the way a phone should do it.
//
// WHAT WAS WRONG BEFORE
//
// This used to be a text box with a floating label and a little dropdown
// of suggestions underneath - a web form, put on a phone. It had all the
// problems web forms have on a phone: the keyboard covered the
// suggestions, the tap targets were small, the label tore a gap through
// the border when it floated, and the whole screen sat there looking like
// something to fill in rather than something to use.
//
// WHAT IT DOES NOW
//
// The same pattern every map app on a phone uses: a big tappable ROW that
// says where you are going, and tapping it opens a FULL SCREEN search with
// the keyboard already up and the results filling everything below it.
// Nothing competes for space, the targets are large, and picking a result
// closes the page and hands the answer back.

import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'theme.dart';

/// Waits this long after the last keystroke before asking the backend, so
/// typing a whole word does not fire one request per letter.
const _debounceDelay = Duration(milliseconds: 300);

/// One tappable row in a "from here, to there" block.
///
/// Shows the chosen place, or a prompt when nothing is chosen yet. It is
/// not a text field at all - it only opens [PlaceSearchPage] and reports
/// back what came out of it.
class PlacePickerRow extends StatelessWidget {
  /// 'From' or 'To'. Used for the prompt and the search page's title.
  final String label;

  /// The place currently chosen, or null.
  final PlaceSuggestion? place;

  final ValueChanged<PlaceSuggestion> onPicked;

  /// Drawn to the left. A dot for the start, a pin for the destination.
  final IconData icon;
  final Color iconColor;

  const PlacePickerRow({
    super.key,
    required this.label,
    required this.place,
    required this.onPicked,
    required this.icon,
    required this.iconColor,
  });

  Future<void> _openSearch(BuildContext context) async {
    final picked = await Navigator.of(context).push<PlaceSuggestion>(
      MaterialPageRoute(builder: (_) => PlaceSearchPage(title: label)),
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final chosen = place != null;

    return InkWell(
      onTap: () => _openSearch(context),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        // Still a comfortable thumb target (well over ~48dp with both
        // lines), just not the oversized block it was on a narrow screen.
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 17, color: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: WimbColors.inkMuted,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    chosen ? place!.stopName : 'Choose a place',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: chosen ? FontWeight.w600 : FontWeight.w400,
                      color: chosen ? WimbColors.ink : WimbColors.inkMuted.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A full-screen place search. Opens with the keyboard up, results fill
/// the rest of the screen, and picking one pops the page returning it.
class PlaceSearchPage extends StatefulWidget {
  /// 'From' or 'To' - only used to title the page.
  final String title;

  const PlaceSearchPage({super.key, required this.title});

  @override
  State<PlaceSearchPage> createState() => _PlaceSearchPageState();
}

class _PlaceSearchPageState extends State<PlaceSearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<PlaceSuggestion> _results = [];
  bool _searching = false;
  bool _hasTyped = false;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();

    if (text.trim().length < 2) {
      setState(() {
        _results = [];
        _hasTyped = text.trim().isNotEmpty;
        _searching = false;
      });
      return;
    }

    setState(() {
      _searching = true;
      _hasTyped = true;
    });

    _debounce = Timer(_debounceDelay, () async {
      final found = await searchPlaces(text);
      if (!mounted) return;
      setState(() {
        _results = found;
        _searching = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WimbColors.cream,
      appBar: AppBar(
        title: Text(widget.title),
        // The search box lives in the app bar itself, so the results get
        // the entire screen below it.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(62),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: TextField(
              controller: _controller,
              // The whole point of a dedicated search page: the keyboard
              // is already up, so there is no extra tap before typing.
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Search stops and places',
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                prefixIcon: const Icon(Icons.search, color: WimbColors.inkMuted, size: 21),
                suffixIcon: _clearOrSpinner(),
                // No visible outline at all - a filled pill reads as a
                // search bar on a phone, where an outlined box with a
                // floating label reads as a form field on a web page.
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      body: _body(),
    );
  }

  Widget? _clearOrSpinner() {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.all(13),
        child: SizedBox(
          width: 17,
          height: 17,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (_controller.text.isEmpty) return null;
    return IconButton(
      icon: const Icon(Icons.close, size: 19, color: WimbColors.inkMuted),
      onPressed: () {
        _controller.clear();
        _onChanged('');
      },
    );
  }

  Widget _body() {
    if (!_hasTyped) {
      return _hint('Start typing a stop or place name.');
    }
    if (_controller.text.trim().length < 2) {
      return _hint('Keep typing - at least two letters.');
    }
    if (_results.isEmpty && !_searching) {
      return _hint('Nothing matches "${_controller.text.trim()}".');
    }

    return ListView.separated(
      // Lets someone scroll the list away to get the keyboard out of the
      // way, rather than having to dismiss it first.
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, i) {
        final place = _results[i];
        return ListTile(
          // Comfortably tappable without aiming.
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          leading: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: WimbColors.dtcRed.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.place_outlined, size: 19, color: WimbColors.dtcRed),
          ),
          title: Text(
            place.stopName,
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500),
          ),
          onTap: () => Navigator.of(context).pop(place),
        );
      },
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 40, 34, 0),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
