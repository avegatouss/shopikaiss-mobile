import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Disposition retenue pour les écrans de l'application.
enum ScreenLayout { compact, standard }

/// Libellés du réglage « Disposition de l'écran ».
const screenLayoutLabels = <String, String>{
  'auto': 'Automatique (compacte sous 6 pouces)',
  'compact': 'Compacte (petit téléphone)',
  'standard': 'Standard (terminal, tablette, grand téléphone)',
};

/// Diagonale en dessous de laquelle un téléphone passe en disposition compacte.
const compactMaxInches = 6.0;

/// Côté le plus court (dp) à partir duquel l'appareil est une tablette ou un terminal : jamais compact en automatique.
const tabletShortestSide = 600.0;

/// Repli sans mesure physique : côté le plus court (dp) d'un petit téléphone (4 à 5,5 pouces ≈ 320 à 360 dp).
const compactShortestSide = 360.0;

/// Choisit la disposition. Les écrans de 6 à 8 pouces et les grands terminaux (14 pouces) restent en `standard` en
/// automatique, exactement comme avant ; seul un téléphone de moins de 6 pouces passe en `compact`.
///
/// [nativeInches] : diagonale mesurée par Android (densité physique de l'écran), retenue si elle est plausible
/// (3 à 30 pouces). Sinon, repli sur la taille logique : compact sous [compactShortestSide] dp de largeur.
ScreenLayout resolveScreenLayout({required String setting, required Size logicalSize, double nativeInches = 0}) {
  if (setting == 'compact') return ScreenLayout.compact;
  if (setting == 'standard') return ScreenLayout.standard;
  final shortest = logicalSize.shortestSide;
  if (shortest <= 0 || shortest >= tabletShortestSide) return ScreenLayout.standard;
  if (nativeInches >= 3 && nativeInches <= 30) {
    return nativeInches < compactMaxInches ? ScreenLayout.compact : ScreenLayout.standard;
  }
  return shortest < compactShortestSide ? ScreenLayout.compact : ScreenLayout.standard;
}

/// Diagonale lue pour l'affichage dans les réglages : mesure Android si plausible, sinon estimation (160 dp ≈ 1 pouce).
double displayedInches(Size logicalSize, double nativeInches) {
  if (nativeInches >= 3 && nativeInches <= 30) return nativeInches;
  return math.sqrt(logicalSize.width * logicalSize.width + logicalSize.height * logicalSize.height) / 160;
}
