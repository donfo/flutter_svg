import 'dart:ui';

import 'package:path_drawing/path_drawing.dart';
import 'package:vector_math/vector_math_64.dart';

import '../utilities/errors.dart';
import '../utilities/numbers.dart';
import '../utilities/xml.dart';
import '../vector_drawable.dart';
import 'colors.dart';
import 'parsers.dart';

double _parseRawWidthHeight(
  String? raw, {
  required double fontSize,
  required double xHeight,
}) {
  if (raw == '100%' || raw == '') {
    return double.infinity;
  }
  assert(() {
    final RegExp notDigits = RegExp(r'[^\d\.]');
    if (!raw!.endsWith('px') &&
        !raw.endsWith('em') &&
        !raw.endsWith('ex') &&
        raw.contains(notDigits)) {
      print(
          'Warning: Flutter SVG only supports the following formats for `width` and `height` on the SVG root:\n'
          '  width="100%"\n'
          '  width="100em"\n'
          '  width="100ex"\n'
          '  width="100px"\n'
          '  width="100" (where the number will be treated as pixels).\n'
          'The supplied value ($raw) will be discarded and treated as if it had not been specified.');
    }
    return true;
  }());
  return parseDoubleWithUnits(raw,
          fontSize: fontSize, xHeight: xHeight, tryParse: true) ??
      double.infinity;
}

/// Parses an SVG @viewBox attribute (e.g. 0 0 100 100) to a [Rect].
///
/// The [nullOk] parameter controls whether this function should throw if there is no
/// viewBox or width/height parameters.
///
/// The [respectWidthHeight] parameter specifies whether `width` and `height` attributes
/// on the root SVG element should be treated in accordance with the specification.
DrawableViewport? parseViewBox(
  Map<String, String> svg, {
  required double fontSize,
  required double xHeight,
  bool nullOk = false,
}) {
  final String? viewBox = getAttribute(svg, 'viewBox');
  final String? rawWidth = getAttribute(svg, 'width');
  final String? rawHeight = getAttribute(svg, 'height');

  if (viewBox == '' && rawWidth == '' && rawHeight == '') {
    if (nullOk) {
      return null;
    }
    throw StateError('SVG did not specify dimensions\n\n'
        'The SVG library looks for a `viewBox` or `width` and `height` attribute '
        'to determine the viewport boundary of the SVG.  Note that these attributes, '
        'as with all SVG attributes, are case sensitive.\n'
        'During processing, the following attributes were found:\n'
        '  $svg');
  }

  final double width =
      _parseRawWidthHeight(rawWidth, fontSize: fontSize, xHeight: xHeight);

  final double height =
      _parseRawWidthHeight(rawHeight, fontSize: fontSize, xHeight: xHeight);

  if (viewBox == '') {
    return DrawableViewport(
      Size(width, height),
      Size(width, height),
    );
  }

  final List<String> parts = viewBox!.split(RegExp(r'[ ,]+'));
  if (parts.length < 4) {
    throw StateError('viewBox element must be 4 elements long');
  }

  return DrawableViewport(
    Size(width, height),
    Size(
      parseDouble(parts[2])!,
      parseDouble(parts[3])!,
    ),
    viewBoxOffset: Offset(
      -parseDouble(parts[0])!,
      -parseDouble(parts[1])!,
    ),
  );
}

/// Builds an IRI in the form of `'url(#id)'`.
String buildUrlIri(Map<String, String> attributes) =>
    'url(#${getAttribute(attributes, 'id')})';

/// An empty IRI.
const String emptyUrlIri = 'url(#)';

/// Parses a `spreadMethod` attribute into a [TileMode].
TileMode parseTileMode(Map<String, String> attributes) {
  final String? spreadMethod =
      getAttribute(attributes, 'spreadMethod', def: 'pad');
  switch (spreadMethod) {
    case 'pad':
      return TileMode.clamp;
    case 'repeat':
      return TileMode.repeated;
    case 'reflect':
      return TileMode.mirror;
    default:
      return TileMode.clamp;
  }
}

/// Parses an @stroke-dasharray attribute into a [CircularIntervalList].
///
/// Does not currently support percentages.
CircularIntervalList<double>? parseDashArray(
  Map<String, String> attributes, {
  required double fontSize,
  required double xHeight,
}) {
  final String? rawDashArray = getAttribute(attributes, 'stroke-dasharray');
  if (rawDashArray == '') {
    return null;
  } else if (rawDashArray == 'none') {
    return DrawableStyle.emptyDashArray;
  }

  final List<String> parts = rawDashArray!.split(RegExp(r'[ ,]+'));
  return CircularIntervalList<double>(parts
      .map((String part) =>
          parseDoubleWithUnits(part, fontSize: fontSize, xHeight: xHeight)!)
      .toList());
}

/// Parses a @stroke-dashoffset into a [DashOffset].
DashOffset? parseDashOffset(
  Map<String, String> attributes, {
  required double fontSize,
  required double xHeight,
}) {
  final String? rawDashOffset = getAttribute(attributes, 'stroke-dashoffset');
  if (rawDashOffset == '') {
    return null;
  }

  if (rawDashOffset!.endsWith('%')) {
    return DashOffset.percentage(parsePercentage(rawDashOffset));
  } else {
    return DashOffset.absolute(parseDoubleWithUnits(
      rawDashOffset,
      fontSize: fontSize,
      xHeight: xHeight,
    )!);
  }
}

/// Parses an @opacity value into a [double], clamped between 0..1.
double? parseOpacity(Map<String, String> attributes) {
  final String? rawOpacity = getAttribute(attributes, 'opacity', def: null);
  if (rawOpacity != null) {
    return parseDouble(rawOpacity)!.clamp(0.0, 1.0).toDouble();
  }
  return null;
}

DrawablePaint _getDefinitionPaint(
  String? key,
  PaintingStyle paintingStyle,
  String iri,
  DrawableDefinitionServer definitions,
  Rect bounds, {
  double? opacity,
}) {
  final Shader? shader = definitions.getShader(iri, bounds);
  if (shader == null) {
    reportMissingDef(key, iri, '_getDefinitionPaint');
  }

  return DrawablePaint(
    paintingStyle,
    shader: shader,
    color: opacity != null ? Color.fromRGBO(255, 255, 255, opacity) : null,
  );
}

/// Parses a @stroke attribute into a [Paint].
DrawablePaint? parseStroke(
  String? key,
  Map<String, String> attributes,
  Rect? bounds,
  DrawableDefinitionServer definitions,
  DrawablePaint? parentStroke,
  Color? currentColor,
  double fontSize,
  double xHeight,
) {
  final String rawStroke = getAttribute(attributes, 'stroke')!;
  final String? rawStrokeOpacity = getAttribute(
    attributes,
    'stroke-opacity',
    def: '1.0',
  );
  final String? rawOpacity = getAttribute(attributes, 'opacity');
  double opacity = parseDouble(rawStrokeOpacity)!.clamp(0.0, 1.0).toDouble();
  if (rawOpacity != '') {
    opacity *= parseDouble(rawOpacity)!.clamp(0.0, 1.0);
  }

  if (rawStroke.startsWith('url')) {
    return _getDefinitionPaint(
      key,
      PaintingStyle.stroke,
      rawStroke,
      definitions,
      bounds!,
      opacity: opacity,
    );
  }
  if (rawStroke == '' && DrawablePaint.isEmpty(parentStroke)) {
    return null;
  }
  if (rawStroke == 'none') {
    return DrawablePaint.empty;
  }

  final String? rawStrokeCap = getAttribute(attributes, 'stroke-linecap');
  final String? rawLineJoin = getAttribute(attributes, 'stroke-linejoin');
  final String? rawMiterLimit = getAttribute(attributes, 'stroke-miterlimit');
  final String? rawStrokeWidth = getAttribute(attributes, 'stroke-width');

  final DrawablePaint paint = DrawablePaint(
    PaintingStyle.stroke,
    color: rawStroke == ''
        ? (parentStroke?.color ?? colorBlack).withOpacity(opacity)
        : (parseColor(rawStroke) ??
                currentColor ??
                parentStroke?.color ??
                colorBlack)
            .withOpacity(opacity),
    strokeCap: rawStrokeCap == 'null'
        ? parentStroke?.strokeCap ?? StrokeCap.butt
        : StrokeCap.values.firstWhere(
            (StrokeCap sc) => sc.toString() == 'StrokeCap.$rawStrokeCap',
            orElse: () => StrokeCap.butt,
          ),
    strokeJoin: rawLineJoin == ''
        ? parentStroke?.strokeJoin ?? StrokeJoin.miter
        : StrokeJoin.values.firstWhere(
            (StrokeJoin sj) => sj.toString() == 'StrokeJoin.$rawLineJoin',
            orElse: () => StrokeJoin.miter,
          ),
    strokeMiterLimit: rawMiterLimit == ''
        ? parentStroke?.strokeMiterLimit ?? 4.0
        : parseDouble(rawMiterLimit),
    strokeWidth: rawStrokeWidth == ''
        ? parentStroke?.strokeWidth ?? 1.0
        : parseDoubleWithUnits(
            rawStrokeWidth,
            fontSize: fontSize,
            xHeight: xHeight,
          ),
  );
  return paint;
}

/// Parses a `fill` attribute.
DrawablePaint? parseFill(
  String? key,
  Map<String, String> el,
  Rect? bounds,
  DrawableDefinitionServer definitions,
  DrawablePaint? parentFill,
  Color? defaultFillColor,
  Color? currentColor,
) {
  final String rawFill = getAttribute(el, 'fill')!;
  final String? rawFillOpacity = getAttribute(el, 'fill-opacity', def: '1.0');
  final String? rawOpacity = getAttribute(el, 'opacity');
  double opacity = parseDouble(rawFillOpacity)!.clamp(0.0, 1.0).toDouble();
  if (rawOpacity != '') {
    opacity *= parseDouble(rawOpacity)!.clamp(0.0, 1.0);
  }

  if (rawFill.startsWith('url')) {
    return _getDefinitionPaint(
      key,
      PaintingStyle.fill,
      rawFill,
      definitions,
      bounds!,
      opacity: opacity,
    );
  }

  if (rawFill == '' && parentFill == DrawablePaint.empty) {
    return null;
  }
  if (rawFill == 'none') {
    return DrawablePaint.empty;
  }

  return DrawablePaint(
    PaintingStyle.fill,
    color: _determineFillColor(
      parentFill?.color,
      rawFill,
      opacity,
      rawOpacity != '' || rawFillOpacity != '',
      defaultFillColor,
      currentColor,
    ),
  );
}

Color? _determineFillColor(
  Color? parentFillColor,
  String rawFill,
  double opacity,
  bool explicitOpacity,
  Color? defaultFillColor,
  Color? currentColor,
) {
  final Color? color = parseColor(rawFill) ??
      currentColor ??
      parentFillColor ??
      defaultFillColor;

  if (explicitOpacity && color != null) {
    return color.withOpacity(opacity);
  }

  return color;
}

/// Parses a `fill-rule` attribute into a [PathFillType].
PathFillType? parseFillRule(Map<String, String> attributes,
    [String attr = 'fill-rule', String? def = 'nonzero']) {
  final String? rawFillRule = getAttribute(attributes, attr, def: def);
  return parseRawFillRule(rawFillRule);
}

/// Applies a transform to a path if the [attributes] contain a `transform`.
Path? applyTransformIfNeeded(Path? path, Map<String, String> attributes) {
  final Matrix4? transform =
      parseTransform(getAttribute(attributes, 'transform', def: null));

  if (transform != null) {
    return path!.transform(transform.storage);
  } else {
    return path;
  }
}

/// Parses a `clipPath` element into a list of [Path]s.
List<Path>? parseClipPath(
  Map<String, String> attributes,
  DrawableDefinitionServer definitions,
) {
  final String? rawClipAttribute = getAttribute(attributes, 'clip-path');
  if (rawClipAttribute != '') {
    return definitions.getClipPath(rawClipAttribute!);
  }

  return null;
}

const Map<String, BlendMode> _blendModes = <String, BlendMode>{
  'multiply': BlendMode.multiply,
  'screen': BlendMode.screen,
  'overlay': BlendMode.overlay,
  'darken': BlendMode.darken,
  'lighten': BlendMode.lighten,
  'color-dodge': BlendMode.colorDodge,
  'color-burn': BlendMode.colorBurn,
  'hard-light': BlendMode.hardLight,
  'soft-light': BlendMode.softLight,
  'difference': BlendMode.difference,
  'exclusion': BlendMode.exclusion,
  'hue': BlendMode.hue,
  'saturation': BlendMode.saturation,
  'color': BlendMode.color,
  'luminosity': BlendMode.luminosity,
};

/// Lookup the mask if the attribute is present.
DrawableStyleable? parseMask(
  Map<String, String> attributes,
  DrawableDefinitionServer definitions,
) {
  final String? rawMaskAttribute = getAttribute(attributes, 'mask');
  if (rawMaskAttribute != '') {
    return definitions.getDrawable(rawMaskAttribute!);
  }

  return null;
}

/// Parses a `font-weight` attribute value into a [FontWeight].
FontWeight? parseFontWeight(String? fontWeight) {
  if (fontWeight == null) {
    return null;
  }
  switch (fontWeight) {
    case '100':
      return FontWeight.w100;
    case '200':
      return FontWeight.w200;
    case '300':
      return FontWeight.w300;
    case 'normal':
    case '400':
      return FontWeight.w400;
    case '500':
      return FontWeight.w500;
    case '600':
      return FontWeight.w600;
    case 'bold':
    case '700':
      return FontWeight.w700;
    case '800':
      return FontWeight.w800;
    case '900':
      return FontWeight.w900;
  }
  throw UnsupportedError('Attribute value for font-weight="$fontWeight"'
      ' is not supported');
}

/// Parses a `font-style` attribute value into a [FontStyle].
FontStyle? parseFontStyle(String? fontStyle) {
  if (fontStyle == null) {
    return null;
  }
  switch (fontStyle) {
    case 'normal':
      return FontStyle.normal;
    case 'italic':
    case 'oblique':
      return FontStyle.italic;
  }
  throw UnsupportedError('Attribute value for font-style="$fontStyle"'
      ' is not supported');
}

/// Parses a `text-decoration` attribute value into a [TextDecoration].
TextDecoration? parseTextDecoration(String? textDecoration) {
  if (textDecoration == null) {
    return null;
  }
  switch (textDecoration) {
    case 'none':
      return TextDecoration.none;
    case 'underline':
      return TextDecoration.underline;
    case 'overline':
      return TextDecoration.overline;
    case 'line-through':
      return TextDecoration.lineThrough;
  }
  throw UnsupportedError('Attribute value for text-decoration="$textDecoration"'
      ' is not supported');
}

/// Parses a `text-decoration-style` attribute value into a [TextDecorationStyle].
TextDecorationStyle? parseTextDecorationStyle(String? textDecorationStyle) {
  if (textDecorationStyle == null) {
    return null;
  }
  switch (textDecorationStyle) {
    case 'solid':
      return TextDecorationStyle.solid;
    case 'dashed':
      return TextDecorationStyle.dashed;
    case 'dotted':
      return TextDecorationStyle.dotted;
    case 'double':
      return TextDecorationStyle.double;
    case 'wavy':
      return TextDecorationStyle.wavy;
  }
  throw UnsupportedError(
      'Attribute value for text-decoration-style="$textDecorationStyle"'
      ' is not supported');
}

/// Parses style attributes or @style attribute.
///
/// Remember that @style attribute takes precedence.
DrawableStyle parseStyle(
  String? key,
  Map<String, String> attributes,
  DrawableDefinitionServer definitions,
  Rect? bounds,
  DrawableStyle? parentStyle, {
  required double fontSize,
  required double xHeight,
  Color? defaultFillColor,
  Color? currentColor,
}) {
  return DrawableStyle.mergeAndBlend(
    parentStyle,
    stroke: parseStroke(
      key,
      attributes,
      bounds,
      definitions,
      parentStyle?.stroke,
      currentColor,
      fontSize,
      xHeight,
    ),
    dashArray: parseDashArray(
      attributes,
      fontSize: fontSize,
      xHeight: xHeight,
    ),
    dashOffset: parseDashOffset(
      attributes,
      fontSize: fontSize,
      xHeight: xHeight,
    ),
    fill: parseFill(
      key,
      attributes,
      bounds,
      definitions,
      parentStyle?.fill,
      defaultFillColor,
      currentColor,
    ),
    pathFillType: parseFillRule(
      attributes,
      'fill-rule',
      parentStyle != null ? null : 'nonzero',
    ),
    groupOpacity: parseOpacity(attributes),
    mask: parseMask(attributes, definitions),
    clipPath: parseClipPath(attributes, definitions),
    textStyle: DrawableTextStyle(
      fontFamily: getAttribute(attributes, 'font-family'),
      fontSize: parseFontSize(
        getAttribute(attributes, 'font-size'),
        parentValue: parentStyle?.textStyle?.fontSize,
        fontSize: fontSize,
        xHeight: xHeight,
      ),
      fontWeight: parseFontWeight(
        getAttribute(attributes, 'font-weight', def: null),
      ),
      fontStyle: parseFontStyle(
        getAttribute(attributes, 'font-style', def: null),
      ),
      anchor: parseTextAnchor(
        getAttribute(attributes, 'text-anchor', def: 'inherit'),
      ),
      decoration: parseTextDecoration(
        getAttribute(attributes, 'text-decoration', def: null),
      ),
      decorationColor: parseColor(
        getAttribute(attributes, 'text-decoration-color', def: null),
      ),
      decorationStyle: parseTextDecorationStyle(
        getAttribute(attributes, 'text-decoration-style', def: null),
      ),
    ),
    blendMode: _blendModes[getAttribute(attributes, 'mix-blend-mode')!],
  );
}
