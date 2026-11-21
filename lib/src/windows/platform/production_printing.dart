import '../../offline/ticket.dart';
import '../../restaurant/resto_engine.dart';
import 'raw_receipt_printer.dart';

/// One immutable engine ticket per spool job, with its own feed and cut.
/// A spooler acknowledgement is transmission, never proof of paper output.
class ProductionPrinting {
  const ProductionPrinting({this.printer = const RawReceiptPrinter()});
  final RawReceiptPrinter printer;

  Future<RestoOutcome> send(String printerName, List<String> lines) async {
    if (printerName.trim().isEmpty || lines.isEmpty) {
      return RestoOutcome.nonEnvoye;
    }
    final result = await printer.send(printerName, offlineTicketBytes(lines));
    return switch (result) {
      RawPrintOutcome.transmitted => RestoOutcome.transmis,
      RawPrintOutcome.notSent => RestoOutcome.nonEnvoye,
      RawPrintOutcome.unknown => RestoOutcome.aVerifier,
    };
  }
}
