<?php

namespace modules;

use Craft;

/** The screenshot site's module: its console commands (app/...) and queue jobs. */
class Module extends \yii\base\Module
{
    public function init(): void
    {
        Craft::setAlias('@modules', __DIR__);
        if (Craft::$app->getRequest()->getIsConsoleRequest()) {
            $this->controllerNamespace = 'modules\\console\\controllers';
        }
        parent::init();
    }
}
