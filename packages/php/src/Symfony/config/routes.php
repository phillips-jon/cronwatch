<?php

// The dashboard's routes. Import them under a prefix, in config/routes/cronwatch.yaml:
//
//     cronwatch:
//         resource: '@CronwatchBundle/config/routes.php'
//         prefix: /cronwatch

declare(strict_types=1);

use Cronwatch\Symfony\DashboardController;
use Symfony\Component\Routing\Loader\Configurator\RoutingConfigurator;

return static function (RoutingConfigurator $routes): void {
    $routes->add('cronwatch_dashboard', '/{path}')
        ->controller(DashboardController::class)
        ->requirements(['path' => '.*'])
        ->defaults(['path' => '']);
};
