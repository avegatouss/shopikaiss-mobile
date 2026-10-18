<?php
// Boutique d'essai locale (ADR-421) : caissier PIN 1234, deux terminaux à session ouverte, deux articles, un code d'appairage par terminal.
chdir(getenv('SHOPIKAISS_WEB') ?: getcwd()); // lancer depuis shopikaiss-web, base d'essai en variables d'environnement
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
use App\Application\Tenancy\DetailedPermissions;
use App\Application\Tenancy\EcasPermissions;
use App\Models\{Enterprise, Store, User, Role, Membership, Terminal, Permission, Product, ProductPackaging, Barcode};
$enterprise = Enterprise::factory()->create(['name' => 'Essai hors ligne']);
$store = Store::factory()->create(['enterprise_id' => $enterprise->id, 'name' => 'Boutique Élégance', 'vat_rate' => '18', 'vat_included' => true]);
$user = User::factory()->create(['active' => true, 'name' => 'Awa Koné', 'email' => 'awa@essai.local']);
$user->forceFill(['pin_hash' => Hash::make('1234')])->save();
$role = Role::factory()->create(['enterprise_id' => $enterprise->id, 'name' => 'admin']);
foreach (DetailedPermissions::expand(EcasPermissions::ALL) as $name) { $role->permissions()->syncWithoutDetaching(Permission::firstOrCreate(['name' => $name])->id); }
$membership = Membership::factory()->create(['enterprise_id' => $enterprise->id, 'store_id' => $store->id, 'user_id' => $user->id, 'role_id' => $role->id]);
$terminals = [Terminal::factory()->create(['enterprise_id' => $enterprise->id, 'store_id' => $store->id, 'name' => 'Comptoir 1']),
    Terminal::factory()->create(['enterprise_id' => $enterprise->id, 'store_id' => $store->id, 'name' => 'Comptoir 2'])];
$codes = [];
foreach ($terminals as $terminal) {
    $session = app('session')->driver();
    $session->put(['tenant_membership_id' => $membership->id, 'tenant_terminal_id' => $terminal->id]);
    Auth::guard()->setUser($user);
    app(App\Application\Cash\CashSessionService::class)->open(10000);
    $codes[] = app(App\Application\OfflineRegister\MobileDeviceService::class)->createPairingCode($terminal->id, 'Essai '.$terminal->name)['code'];
}
$scope = ['enterprise_id' => $enterprise->id, 'store_id' => $store->id];
$soap = Product::factory()->create($scope + ['name' => 'Savon à l’huile', 'sale_price' => 1000, 'purchase_price' => 400, 'unlimited_stock' => false]);
$rice = Product::factory()->create($scope + ['name' => 'Riz parfumé 1 kg', 'sale_price' => 333, 'purchase_price' => 200, 'unlimited_stock' => false]);
app(App\Application\Inventory\StockService::class)->correct($soap, '5', (string) Str::uuid(), 'opening', 'Stock essai');
(new Barcode)->forceFill($scope + ['uuid' => (string) Str::uuid(), 'product_id' => $soap->id, 'code' => '6190000000011', 'is_primary' => true])->save();
echo json_encode(['codes' => $codes, 'savon' => $soap->id, 'riz' => $rice->id, 'caissier' => $user->id]), "\n";
