/// Rule-driven deconjugation, ported from meikipop's deconjugator.
///
/// Rules come from the study dictionary's `deconjugator_rules`; each turns a
/// conjugated ending (`con_end`) back into its dictionary ending (`dec_end`),
/// tagging the result with the part of speech it must belong to.
library;

class DeconjugatedForm {
  final String text;
  final List<String> process;
  final List<String> tags;

  const DeconjugatedForm(this.text, {this.process = const [], this.tags = const []});

  String get _key => '$text\u0000${process.join('\u0001')}\u0000${tags.join('\u0001')}';

  @override
  bool operator ==(Object other) => other is DeconjugatedForm && other._key == _key;

  @override
  int get hashCode => _key.hashCode;
}

class _Rule {
  final String type;
  final List<String> decEnds;
  final List<String> conEnds;
  final List<String>? decTags;
  final List<String>? conTags;
  final String detail;
  final int variants;

  _Rule(this.type, this.decEnds, this.conEnds, this.decTags, this.conTags, this.detail, this.variants);
}

class Deconjugator {
  static const _maxIterations = 10;
  static const _starterTypes = {'stdrule', 'rewriterule', 'onlyfinalrule', 'contextrule'};

  final List<_Rule> _rules;

  Deconjugator(List<dynamic> rawRules) : _rules = [for (final r in rawRules) ?_parse(r)];

  static List<String>? _list(Object? v) => switch (v) {
    null => null,
    final List<dynamic> l => [for (final e in l) e.toString()],
    _ => [v.toString()],
  };

  static _Rule? _parse(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type']?.toString();
    if (type == null || type == 'substitution') return null;
    if (!raw.containsKey('dec_end') || !raw.containsKey('con_end')) return null;
    final decEnds = _list(raw['dec_end'])!;
    final conEnds = _list(raw['con_end'])!;
    final decTags = _list(raw['dec_tag']);
    final conTags = _list(raw['con_tag']);
    // Like the Python original, the first list-valued field sets the variant count.
    var variants = 1;
    for (final v in [raw['dec_end'], raw['con_end'], raw['dec_tag'], raw['con_tag']]) {
      if (v is List) {
        variants = v.length;
        break;
      }
    }
    return _Rule(type, decEnds, conEnds, decTags, conTags, raw['detail']?.toString() ?? '', variants);
  }

  Set<DeconjugatedForm> deconjugate(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return {};

    final processed = <DeconjugatedForm>{};
    var novel = <DeconjugatedForm>{DeconjugatedForm(clean)};
    var iteration = 0;
    while (novel.isNotEmpty && ++iteration <= _maxIterations) {
      final next = <DeconjugatedForm>{};
      for (final form in novel) {
        for (final rule in _rules) {
          if (rule.type == 'onlyfinalrule' && form.tags.isNotEmpty) continue;
          if (rule.type == 'neverfinalrule' && form.tags.isEmpty) continue;
          for (final f in _apply(form, rule)) {
            if (!processed.contains(f) && !novel.contains(f)) next.add(f);
          }
        }
      }
      processed.addAll(novel);
      novel = next;
    }
    processed.add(DeconjugatedForm(clean));
    return processed;
  }

  Iterable<DeconjugatedForm> _apply(DeconjugatedForm form, _Rule rule) sync* {
    for (var i = 0; i < rule.variants; i++) {
      final conEnd = rule.conEnds.isEmpty ? '' : rule.conEnds[i % rule.conEnds.length];
      final decEnd = rule.decEnds.isEmpty ? '' : rule.decEnds[i % rule.decEnds.length];
      final conTag = rule.conTags == null || rule.conTags!.isEmpty ? null : rule.conTags![i % rule.conTags!.length];
      final decTag = rule.decTags == null || rule.decTags!.isEmpty ? null : rule.decTags![i % rule.decTags!.length];

      if (!form.text.endsWith(conEnd)) continue;
      final tagMatch = form.tags.isEmpty ? _starterTypes.contains(rule.type) : form.tags.last == conTag;
      if (!tagMatch) continue;
      if (rule.type == 'rewriterule' && form.text != conEnd) continue;

      final stem = form.text.substring(0, form.text.length - conEnd.length);
      final base = form.tags.isEmpty ? const <String>[] : form.tags.sublist(0, form.tags.length - 1);
      yield DeconjugatedForm(
        stem + decEnd,
        process: [...form.process, rule.detail],
        tags: decTag == null ? base : [...base, decTag],
      );
    }
  }
}
