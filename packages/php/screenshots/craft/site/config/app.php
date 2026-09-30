<?php
// The screenshot site's application config: Craft's own, and the site's module (id "app").

use craft\helpers\App;

return [
    'id' => App::env('CRAFT_APP_ID') ?: 'CraftCMS',
    'modules' => ['app' => modules\Module::class],
    'bootstrap' => ['app'],
];
