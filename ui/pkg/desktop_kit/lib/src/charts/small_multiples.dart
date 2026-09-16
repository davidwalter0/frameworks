// A responsive small-multiples grid: N same-shaped facets (e.g. one
// [LineChart] per seed, or per arm), each in its own titled card, wrapped to
// as many columns as the available width allows down to [minFacetWidth]
// each. Small multiples are how this kit's charting rules stay satisfied
// when a single plot would otherwise need a second y-scale or an
// unreadable pile of series: facet the data instead of dual-axing it or
// cramming every entity onto one plot (dataviz skill non-negotiable #2 —
// "one axis").
//
// New in this promotion (not present in ghk_dashboard, which has no faceted
// use case yet) — see chart_series.dart's library doc for the sibling
// components' provenance.
library;

import 'package:flutter/material.dart';

/// One facet: a [title] (e.g. `'seed 3'`) and the content to render below it
/// — typically a [LineChart], but any widget works so a facet can also be a
/// [StateStrip], a scatter, or plain text.
@immutable
class SmallMultipleFacet {
  const SmallMultipleFacet({required this.title, required this.child});

  /// Shown above [child], identifying which slice of the data this facet
  /// is (a seed, an arm, a cell, ...).
  final String title;

  /// The facet's content.
  final Widget child;
}

/// Lays out [facets] as a responsive wrap grid of titled cards. Facets are
/// never resized below [minFacetWidth]; instead the column count drops,
/// down to one (full-width, stacked) on a narrow window — the same
/// "collapse on measured extent" rule the kit's other responsive layouts
/// follow, rather than a hard-coded breakpoint.
class SmallMultiples extends StatelessWidget {
  /// Creates a small-multiples grid.
  const SmallMultiples({
    super.key,
    required this.facets,
    required this.emptyMessage,
    this.minFacetWidth = 320,
    this.spacing = 12,
  });

  /// The facets to render; empty shows [emptyMessage] instead.
  final List<SmallMultipleFacet> facets;

  /// Shown instead of the grid when [facets] is empty.
  final String emptyMessage;

  /// The narrowest a facet card is allowed to get before the column count
  /// drops instead.
  final double minFacetWidth;

  /// Gap between facet cards, both axes.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (facets.isEmpty) {
      final ColorScheme cs = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : minFacetWidth;
        final int columns = ((available + spacing) / (minFacetWidth + spacing))
            .floor()
            .clamp(1, facets.length);
        final double facetWidth =
            (available - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final SmallMultipleFacet f in facets)
              SizedBox(
                key: ValueKey<String>('facet-${f.title}'),
                width: facetWidth,
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          f.title,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        f.child,
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
