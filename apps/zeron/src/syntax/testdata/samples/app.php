<?php
declare(strict_types=1);
namespace App\Models;
use Foo\Bar as Baz;
// comment
/** Doc */
final class User extends Model implements JsonSerializable {
    public const MAX = 10;
    private static ?array $cache = null;
    public function __construct(private string $name, protected int $age = 0) {}
    public function greet(string $who = "world"): string {
        $msg = "Hello {$who} and $this->name";
        return sprintf('%s!', $msg) . PHP_EOL;
    }
}
$u = new User("a"); echo $u->greet(), true, null, 1.5;
function helper(array $xs): array { return array_map(fn($x) => $x * 2, $xs); }
