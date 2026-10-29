/// Abonnement aux changements du moteur, sans Flutter : le moteur de caisse tourne aussi dans un hôte Dart pur (Windows).
///
/// Même usage que `ChangeNotifier` pour les écrans (`addListener` / `removeListener`). Une erreur d'abonné n'interrompt
/// JAMAIS le moteur : une notification part souvent juste après une écriture durable (vente enregistrée), et une
/// exception d'écran ne doit pas faire croire que la vente a échoué. L'erreur est transmise à [onListenerError].
class EngineNotifier {
  final List<void Function()> _listeners = [];

  /// Rapport des erreurs d'abonnés (journal de l'application) ; ignorées si absent.
  static void Function(Object error, StackTrace stack)? onListenerError;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  bool get hasListeners => _listeners.isNotEmpty;

  void notifyListeners() {
    for (final listener in List.of(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (error, stack) {
        onListenerError?.call(error, stack);
      }
    }
  }
}
