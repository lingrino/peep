<?php
declare(strict_types=1);

namespace App;

final class Router
{
    /** @var array<string, callable> */
    private array $routes = [];

    public function get(string $path, callable $handler): self
    {
        $this->routes["GET $path"] = $handler;
        return $this;
    }

    public function dispatch(string $method, string $path): string
    {
        $handler = $this->routes["$method $path"] ?? null;
        return $handler ? (string) $handler() : "404 Not Found";
    }
}

$router = (new Router())->get('/', fn () => 'Home')->get('/about', fn () => "About {$_SERVER['HTTP_HOST'] ?? 'local'}");
echo $router->dispatch('GET', '/about'), PHP_EOL;
