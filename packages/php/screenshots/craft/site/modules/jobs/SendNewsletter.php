<?php

namespace modules\jobs;

use craft\queue\BaseJob;
use modules\Demo;

/** The morning newsletter, queued when the day's edition is published. */
class SendNewsletter extends BaseJob
{
    public function execute($queue): void
    {
        $sent = (int) Demo::get('sent', 12_480);
        Demo::log('Rendering "' . Demo::get('edition', 'New in this week') . '"');
        Demo::log("Sent to {$sent} subscribers in " . (int) ceil($sent / 500) . ' batches');
        Demo::metric('sent', $sent);
    }

    protected function defaultDescription(): ?string
    {
        return 'Sending the newsletter';
    }
}
