<?php
// Régénère test/fixtures/calcul_serveur.json depuis le vrai SaleCalculator. Depuis shopikaiss-web :
//   php ../shopikaiss-mobile/tool/calcul_serveur.php ../shopikaiss-mobile/test/fixtures/calcul_serveur.json
require 'vendor/autoload.php';
use App\Domain\Sales\SaleCalculator;
$calc = new SaleCalculator;
mt_srand(421);
$cases = [];
$fixed = [
  [[['unit_price'=>333,'quantity'=>'0.5','line_discount'=>0]], '0', 'INCLUSE'],
  [[['unit_price'=>1000,'quantity'=>'1','line_discount'=>0]], '18', 'AJOUTEE'],
  [[['unit_price'=>1180,'quantity'=>'1','line_discount'=>0]], '18', 'INCLUSE'],
  [[['unit_price'=>1001,'quantity'=>'1','line_discount'=>0]], '18.000000', 'INCLUSE'],
  [[['unit_price'=>250,'quantity'=>'2.125','line_discount'=>31],['unit_price'=>99,'quantity'=>'3','line_discount'=>0]], '9.5', 'AJOUTEE'],
  [[['unit_price'=>10,'quantity'=>'0.05','line_discount'=>5]], '18', 'INCLUSE'],
];
foreach ($fixed as $f) { $cases[] = $f; }
for ($i = 0; $i < 300; $i++) {
  $lines = [];
  for ($j = 0, $n = mt_rand(1, 5); $j < $n; $j++) {
    $price = mt_rand(0, 3) === 0 ? mt_rand(1, 99) : mt_rand(100, 250000);
    $q = mt_rand(0,2)===0 ? (mt_rand(1,9999)/1000) : mt_rand(1, 12);
    $qs = rtrim(rtrim(number_format($q, 3, '.', ''), '0'), '.');
    $base = (int) round($price * $q);
    $lines[] = ['unit_price'=>$price,'quantity'=>$qs,'line_discount'=>mt_rand(0,3)===0 ? mt_rand(0, max(0,(int)($base/5))) : 0];
  }
  $rates = ['0','18','18.000000','9','5.5','10.25'];
  $cases[] = [$lines, $rates[array_rand($rates)], mt_rand(0,1) ? 'INCLUSE' : 'AJOUTEE'];
}
$out = [];
foreach ($cases as [$lines, $rate, $mode]) {
  $r = $calc->calculate($lines, 0, $rate, $mode);
  $out[] = ['lignes'=>$lines, 'tva'=>$rate, 'mode'=>$mode, 'totaux_lignes'=>$r['line_totals'], 'brut'=>$r['gross'], 'tva_montant'=>$r['vat'], 'net'=>$r['net'], 'base_ht'=>$r['base_ht']];
}
file_put_contents($argv[1], json_encode(['source'=>'App\Domain\Sales\SaleCalculator (shopikaiss-web, branche hors-ligne/caisse-mobile-2026-10-18)', 'cas'=>$out], JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES));
echo count($out)." cas\n";
