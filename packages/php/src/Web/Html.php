<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Cronwatch\Duration;
use Cronwatch\JobSummary;
use Cronwatch\Js;
use Cronwatch\Run;

/**
 * The dashboard's pages, markup for markup the SDK's routes/html.ts. The one
 * script, app.js, registers the service worker and toggles the theme: the pages refresh
 * themselves and the forget button confirms with a <details>.
 *
 * Set like cronwatch.dev: a printed sheet on grey paper, a serif for what a
 * person reads, a mono for what a machine printed, neutral greys, and colour
 * only for the states CronWatch reports. The page loads nothing but its own
 * app shell (its CSP is default-src 'none' plus 'self' for the script, the
 * manifest, the worker, and images), so the fonts are system stacks that echo
 * the site's Newsreader and IBM Plex Mono, and use them when they are installed.
 *
 * Installed as an app (display-mode: standalone) the header stays at the top
 * as the app's bar, and the page keeps clear of notches and the home
 * indicator with the safe-area insets (the viewport is viewport-fit=cover).
 *
 * Motion is CSS only and says something: marks arrive in time order, the now
 * line drops in last, and open problems (a missed slot, a running bar)
 * breathe slowly. prefers-reduced-motion turns all of it off.
 *
 * @internal
 */
final class Html
{
    /** The pages' stylesheet: inline in a standalone page (StandaloneHead), a file of its own where a host loads it. */
    public const CSS = <<<'CSS'

:root{color-scheme:light dark;--paper:#f4f4f5;--sheet:#fff;--sunk:#fafafa;--rule:#e4e4e7;--rule-2:#d4d4d8;--tick:#909098;--ink:#000;--body:#18181b;--muted:#71717a;--ok:#15803d;--warn:#a16207;--bad:#b91c1c;--serif:"Newsreader",ui-serif,Georgia,Cambria,"Times New Roman",serif;--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;--who:200px}
@media(prefers-color-scheme:dark){:root:not([data-theme=light]){--paper:#09090b;--sheet:#111113;--sunk:#18181b;--rule:#27272a;--rule-2:#3f3f46;--tick:#66666f;--ink:#fff;--body:#e4e4e7;--muted:#a1a1aa;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}}
:root[data-theme=light]{color-scheme:light}:root[data-theme=dark]{color-scheme:dark;--paper:#09090b;--sheet:#111113;--sunk:#18181b;--rule:#27272a;--rule-2:#3f3f46;--tick:#66666f;--ink:#fff;--body:#e4e4e7;--muted:#a1a1aa;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--paper);color:var(--ink);font:400 16px/1.55 var(--serif);-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
a{color:inherit;text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:.16em;text-decoration-color:var(--rule-2)}a:hover{text-decoration-color:currentColor}
:focus-visible{outline:2px solid var(--ink);outline-offset:2px}
code,pre,.mono{font-family:var(--mono)}
.vh{position:absolute!important;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
.sheet{max-width:1180px;min-height:100vh;margin:0 auto;background:var(--sheet);border-inline:1px solid var(--rule);padding:0 clamp(16px,4vw,48px)}
.top{display:flex;align-items:center;justify-content:space-between;gap:12px 20px;flex-wrap:wrap;padding:18px 0 17px;border-bottom:1px solid var(--rule)}
.brand{display:flex;align-items:center;gap:10px;margin:0;font:600 18px/1.2 var(--serif);letter-spacing:-.01em;min-width:0}
.brand a{display:inline-flex;align-items:center;gap:10px;text-decoration:none}.brand svg{width:24px;height:24px;flex:none;color:var(--ink)}
.brand .crumb{font:500 15px/1.2 var(--mono);color:var(--body);overflow-wrap:anywhere}.brand .slash{color:var(--rule-2);font-weight:400}
.actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.meta{font:400 12px/1.4 var(--mono);color:var(--muted)}
button,a.button,details.confirm>summary{font:500 12.5px/1 var(--mono);color:var(--ink);background:var(--sheet);border:1px solid var(--rule-2);border-radius:3px;height:32px;padding:0 11px;cursor:pointer}
a.button{display:inline-flex;align-items:center;text-decoration:none}
button:hover,a.button:hover,details.confirm>summary:hover{border-color:var(--muted)}
button.primary{background:var(--ink);border-color:var(--ink);color:var(--sheet)}button.primary:hover{opacity:.86}button.danger{color:var(--bad)}button.danger:hover{border-color:var(--bad)}
form.inline{display:inline-flex;align-items:center;gap:6px;margin:0}
details.confirm{display:inline-flex;align-items:center;flex-wrap:wrap;gap:8px;margin:0}details.confirm>summary{list-style:none;display:inline-flex;align-items:center}
details.confirm>summary::-webkit-details-marker{display:none}details.confirm[open]>summary{border-color:var(--muted)}
details.confirm form{flex-wrap:wrap;font-size:14px;color:var(--muted)}.delete details{margin-top:16px}
.sec{display:grid;grid-template-columns:150px minmax(0,1fr);gap:10px 40px;padding:30px 0;border-top:1px solid var(--rule)}
.top+main>.sec:first-child{border-top:0}
.sec>h2{margin:0;font:500 11px/1.5 var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--muted);padding-top:5px}
.sec>.wide{grid-column:1/-1;min-width:0}
.lede{margin:0;color:var(--muted);font-size:16px;max-width:64ch;text-wrap:pretty}
.headline{margin:0;font:400 clamp(24px,3.2vw,32px)/1.2 var(--serif);letter-spacing:-.01em;text-wrap:balance}
.headline b{font-weight:600}
.state{font:500 12.5px/1.4 var(--mono);white-space:nowrap}.state+.state::before{content:" \00b7  ";color:var(--muted);font-weight:400}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.muted{color:var(--muted)}.info{color:var(--ink)}
.sq{display:inline-block;width:8px;height:8px;border-radius:1.5px;background:currentColor;margin-right:7px;vertical-align:1px;flex:none}
.sq.muted{background:none;box-shadow:inset 0 0 0 1.5px var(--tick)}
.figures{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:0;margin:22px 0 0;border-top:1px solid var(--rule)}
.figures>div{display:flex;flex-direction:column-reverse;justify-content:flex-end;gap:4px;padding:14px 16px 2px 0}
.figures dt{font:500 11px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);display:flex;align-items:center}
.figures dd{margin:0;font:400 30px/1.1 var(--serif);font-variant-numeric:tabular-nums;color:var(--ink)}
.figures dd small{font-size:17px;color:var(--muted)}
.figures .zero dd{color:var(--rule-2)}
.figures .bad dd{color:var(--bad)}.figures .warn dd{color:var(--warn)}
.stateline{margin:12px 0 0;display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px}
.stateline .why{font-style:italic;color:var(--muted)}
.jobname{margin:0;font:500 clamp(22px,3vw,28px)/1.2 var(--mono);letter-spacing:-.01em;overflow-wrap:anywhere}
.desc{margin:6px 0 0;color:var(--body);max-width:64ch}
.intro .actions{margin-top:18px}
table{width:100%;border-collapse:collapse}
th{text-align:left;font:500 10.5px/1.2 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);padding:0 14px 10px 0;border-bottom:1px solid var(--rule);white-space:nowrap}
td{padding:12px 14px 12px 0;border-bottom:1px solid var(--rule);vertical-align:top;font:400 12.5px/1.5 var(--mono);color:var(--body)}
tbody tr:last-child td{border-bottom:0}
td.job{font-family:var(--serif);font-size:15px;min-width:180px}
td.job .name{font:500 13.5px/1.5 var(--mono);color:var(--ink)}
td.job .desc{display:block;margin:2px 0 0;font-size:14px;color:var(--muted);line-height:1.4}
td .tz,td .sub{display:block;color:var(--muted);font-size:11.5px}
.nowrap{white-space:nowrap}
.spark{display:block;overflow:visible}.spark rect{fill:var(--tick)}.spark rect.bad{fill:var(--bad)}.spark rect.warn{fill:var(--warn)}.spark rect.running{fill:none;stroke:var(--ink);stroke-width:1}
.runs td{padding-top:11px;padding-bottom:11px}.runs tr.has-detail td{border-bottom:0;padding-bottom:4px}.runs tr.detail td{padding-top:0}
.metrics{display:flex;flex-wrap:wrap;gap:2px 14px}.metrics .k{color:var(--muted)}
pre{margin:6px 0 0;padding:12px 14px;background:var(--sunk);border:1px solid var(--rule);border-radius:3px;font:400 12.5px/1.55 var(--mono);color:var(--body);white-space:pre-wrap;overflow-wrap:anywhere;max-height:340px;overflow:auto}
details.out{margin-top:4px}details.out>summary{cursor:pointer;font:400 12px/1.6 var(--mono);color:var(--muted)}details.out>summary:hover{color:var(--ink)}
details.out.error>summary{color:var(--bad)}
dl.def{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:8px 28px;margin:0}
dl.def dt{font:500 11px/1.9 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
dl.def dd{margin:0;font:400 13.5px/1.7 var(--mono);color:var(--body);overflow-wrap:anywhere}dl.def dd.prose{font:400 16px/1.55 var(--serif)}
.empty{padding:28px 0 8px;color:var(--muted);max-width:60ch}
.empty code{font-size:.86em;color:var(--ink)}
.message{padding:clamp(56px,12vh,120px) 0;text-align:center}
.message h1{margin:0;font:400 clamp(28px,4vw,40px)/1.15 var(--serif);letter-spacing:-.015em}
.message p{margin:14px auto 0;max-width:52ch;color:var(--muted);text-wrap:pretty}
.signin{display:flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:8px;margin:28px auto 0;max-width:420px}
.signin label{font:500 11px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.signin input{flex:1 1 180px;min-width:0;font:400 16px/1.2 var(--mono);color:var(--ink);background:var(--sheet);border:1px solid var(--rule-2);border-radius:3px;height:32px;padding:0 10px}
footer{display:flex;flex-wrap:wrap;gap:6px 18px;padding:20px 0 40px;border-top:1px solid var(--rule);font:400 12px/1.5 var(--mono);color:var(--muted)}footer .version{margin-left:auto}
.timeline{margin:18px 0 0}
.timeline .axis,.timeline .under,.timeline .over,.timeline .lane{display:grid;grid-template-columns:var(--who) minmax(0,1fr)}
.timeline .hours{position:relative;height:22px;font:400 11px/1 var(--mono);color:var(--muted);letter-spacing:.04em}
.timeline .hours span{position:absolute;top:2px;transform:translateX(-50%);white-space:nowrap}
.timeline .hours .nowlabel{color:var(--ink);font-weight:500;animation:cw-fade .5s 1s both}
.timeline .field{position:relative}
.timeline .under,.timeline .over{position:absolute;inset:0;pointer-events:none}
.timeline .under>div,.timeline .over>div{position:relative}
.timeline .gl{position:absolute;top:0;bottom:0;width:1px;background:var(--rule)}
.timeline .future{position:absolute;top:0;bottom:0;right:0;background:var(--sunk)}
.timeline .now{position:absolute;top:-6px;bottom:0;width:1.5px;margin-left:-.75px;background:var(--ink);transform-origin:top;animation:cw-drop .6s .85s cubic-bezier(.2,.8,.2,1) both}
.timeline .lanes{position:relative;list-style:none;margin:0;padding:0;border-top:1px solid var(--rule);border-bottom:1px solid var(--rule)}
.timeline .lane{align-items:center;min-height:40px}
.timeline .who{display:grid;grid-template-columns:auto minmax(0,1fr);align-items:center;column-gap:0;padding:6px 14px 6px 0;min-width:0}
.timeline .who .sched{grid-column:2}
.timeline.week .who{display:flex;align-items:baseline;gap:10px}
.timeline .who .name{font:500 13px/1.35 var(--mono);color:var(--ink);overflow-wrap:anywhere}
.timeline .who .sched{font:400 11px/1.35 var(--mono);color:var(--muted);white-space:nowrap}
.timeline .track{position:relative;height:24px}
.timeline .marks{display:block;width:100%;height:24px;overflow:visible}
.timeline .note{position:absolute;top:50%;transform:translateY(-50%);font:italic 400 14px/1.2 var(--serif);color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 3px;text-shadow:0 0 3px var(--sheet),0 0 3px var(--sheet),0 0 6px var(--sheet);animation:cw-fade .6s 1.1s both}
.timeline .note.before{text-align:right}
.timeline .legend{display:flex;flex-wrap:wrap;gap:6px 18px;margin:14px 0 0;padding-left:var(--who);font:400 11.5px/1.4 var(--mono);color:var(--muted)}
.timeline .legend span{display:inline-flex;align-items:center;gap:7px}
.timeline .more{margin:10px 0 0;padding-left:var(--who);font-size:14px;color:var(--muted);font-style:italic}
.key{width:16px;height:12px;overflow:visible}
.marks *{vector-effect:non-scaling-stroke}
svg .base{stroke:var(--rule);stroke-width:1}
svg .tick{stroke:var(--tick);stroke-width:1.5}svg .tick.ahead{stroke-dasharray:2 2;opacity:.75}
svg .cadence{stroke:var(--tick);stroke-width:2;stroke-dasharray:1 3}
svg .run{stroke-width:2;stroke-linejoin:round}
svg .run.ok{fill:var(--ok);stroke:var(--ok)}
svg .run.bad{fill:var(--bad);stroke:var(--bad)}
svg .run.timeout{fill:var(--bad);fill-opacity:.28;stroke:var(--bad);stroke-width:1.5}
svg .run.warn{fill:var(--warn);stroke:var(--warn)}
svg .run.running{fill:none;stroke:var(--ink);stroke-width:1.5}
svg .run.stuck{fill:var(--bad);fill-opacity:.12;stroke:var(--bad);stroke-width:1.5}
svg .missed{fill:none;stroke:var(--bad);stroke-width:1.5;stroke-dasharray:3 2.5}
svg .unloaded{fill:var(--sunk)}
svg .ahead{fill:var(--sunk)}
svg .nowline{stroke:var(--ink);stroke-width:1.5}
.marks .tick{animation:cw-fade .4s var(--d,0ms) both}
.marks .run,.marks .missed{transform-box:fill-box;transform-origin:0 50%;animation:cw-grow .55s cubic-bezier(.2,.8,.2,1) var(--d,0ms) both}
.marks .missed,.marks .run.running,.marks .run.stuck{animation:cw-grow .55s cubic-bezier(.2,.8,.2,1) var(--d,0ms) both,cw-breathe 2.6s ease-in-out calc(var(--d,0ms) + .6s) infinite alternate}
.figures>div{animation:cw-rise .5s cubic-bezier(.2,.8,.2,1) both}
.figures>div:nth-child(2){animation-delay:40ms}.figures>div:nth-child(3){animation-delay:80ms}.figures>div:nth-child(4){animation-delay:120ms}.figures>div:nth-child(5){animation-delay:160ms}.figures>div:nth-child(6){animation-delay:200ms}
@keyframes cw-fade{from{opacity:0}}
@keyframes cw-grow{from{opacity:0;transform:scaleX(0)}}
@keyframes cw-drop{from{opacity:0;transform:scaleY(0)}}
@keyframes cw-rise{from{opacity:0;transform:translateY(4px)}}
@keyframes cw-breathe{to{opacity:.38}}
body{padding:0 env(safe-area-inset-right) 0 env(safe-area-inset-left)}
footer{padding-bottom:calc(40px + env(safe-area-inset-bottom))}
@media(display-mode:standalone){
.top{position:sticky;top:0;z-index:2;background:var(--sheet);padding-top:calc(14px + env(safe-area-inset-top));padding-bottom:13px;-webkit-user-select:none;user-select:none}
.message{padding-top:clamp(40px,8vh,80px)}
}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
@media(max-width:760px){
.sec{grid-template-columns:minmax(0,1fr);gap:10px;padding:24px 0}
.hide-sm{display:none}
:root{--who:0px}
.timeline .lane{grid-template-columns:minmax(0,1fr);padding:6px 0 8px}
.timeline .who{padding:0 0 4px}
.timeline .who .name{background:var(--sheet);padding-right:4px}
.timeline .hours .minor,.timeline .hours .near{display:none}
.timeline .note{font-size:13px}
td.job{min-width:0}
table.board thead{display:none}
table.board tr{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:14px;padding:12px 0;border-bottom:1px solid var(--rule)}
table.board tbody tr:last-child{border-bottom:0}
table.board td{border:0;padding:0}
table.board td.last{grid-column:1/-1;margin-top:4px;white-space:normal}
table.board td.last .sub{display:inline;margin-left:8px}
.runs td.nowrap{white-space:normal}
dl.def{grid-template-columns:minmax(0,1fr);gap:0}dl.def dd{margin-bottom:10px}
}

CSS;

    /** The clock face from cronwatch.dev, in the text colour. */
    private const MARK = '<svg viewBox="0 0 40 40" aria-hidden="true" focusable="false"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="none" stroke="currentColor" stroke-opacity=".22" stroke-width="1.5"/><circle cx="20" cy="20" r="10.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

    /** In the order the board counts them, the ones needing attention first. */
    private const HEALTH = [
        'failing' => ['bad', 'failing'],
        'stuck' => ['bad', 'stuck'],
        'late' => ['warn', 'late'],
        'healthy' => ['ok', 'healthy'],
        'silenced' => ['muted', 'silenced'],
        'never_ran' => ['muted', 'never ran'],
    ];

    /** Conditions the health state already says; the others are named after it. */
    private const SHOWN_BY_HEALTH = ['missed', 'failed', 'stuck'];

    /** What the empty board tells a PHP app to write (the SDK shows its own TypeScript). */
    public const DECLARE_ONE = "\$cw->job('name', ['schedule' => '0 2 * * *'])";

    /**
     * A page. `base` is where the dashboard is mounted ("" at the root).
     * The head's assets are StandaloneHead's (the manifest, the icons,
     * app.js and the stylesheet inline) unless `head` is given: then they
     * are what it returns for the base, for a host that shows the dashboard
     * inside its own pages and loads their assets its own way.
     *
     * @param (\Closure(string): string)|null $head
     */
    public static function layout(string $title, string $body, string $base, ?int $refresh = null, ?\Closure $head = null): string
    {
        $b = Text::h($base);
        $meta = $refresh ? '<meta http-equiv="refresh" content="' . $refresh . '">' : '';
        return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            . "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">\n"
            . "<meta name=\"robots\" content=\"noindex,nofollow\">\n"
            . "<meta name=\"color-scheme\" content=\"light dark\">\n"
            . "{$meta}\n"
            . '<title>' . Text::h($title) . "</title>\n"
            . '<meta name="theme-color" content="' . Pwa::THEME_COLOR . "\" media=\"(prefers-color-scheme: light)\">\n"
            . '<meta name="theme-color" content="' . Pwa::THEME_COLOR_DARK . "\" media=\"(prefers-color-scheme: dark)\">\n"
            . "<meta name=\"mobile-web-app-capable\" content=\"yes\">\n"
            . "<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">\n"
            . "<meta name=\"apple-mobile-web-app-title\" content=\"CronWatch\">\n"
            . "<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"default\">\n"
            . ($head === null ? StandaloneHead::html($b) : $head($base))
            . "</head>\n"
            . "<body><div class=\"sheet\">{$body}</div></body>\n"
            . '</html>';
    }

    private static function brand(string $base, ?string $crumb = null): string
    {
        $home = '<a href="' . Text::h($base) . '/">' . self::MARK . '<span>CronWatch</span></a>';
        return $crumb === null
            ? "<p class=\"brand\">{$home}</p>"
            : "<p class=\"brand\">{$home}<span class=\"slash\" aria-hidden=\"true\">/</span><span class=\"crumb\">" . Text::name($crumb) . '</span></p>';
    }

    /** The job's health, with any open condition it does not already say (over budget, under floor, slow) after it. */
    private static function healthState(JobSummary $job): string
    {
        [$cls, $label] = self::HEALTH[$job->health];
        $extras = '';
        foreach ($job->open as $condition) {
            if (!in_array($condition, self::SHOWN_BY_HEALTH, true)) {
                $extras .= '<span class="state warn">' . Text::h(self::spaced($condition)) . '</span>';
            }
        }
        return "<span class=\"state {$cls}\"><i class=\"sq {$cls}\" aria-hidden=\"true\"></i>{$label}</span>{$extras}";
    }

    /** condition.replace("_", " "): the first underscore only, as a string pattern replaces. */
    private static function spaced(string $condition): string
    {
        $at = strpos($condition, '_');
        return $at === false ? $condition : substr_replace($condition, ' ', $at, 1);
    }

    private static function runState(Run $run): string
    {
        $cls = $run->status === 'ok' ? 'ok' : ($run->status === 'running' ? 'info' : 'bad');
        return "<span class=\"state {$cls}\">" . Text::h($run->status) . '</span>';
    }

    /**
     * The last twenty runs, oldest first, as bars as tall as they took; grey unless something went wrong.
     *
     * @param list<Run> $runs
     */
    private static function sparkline(array $runs): string
    {
        $points = array_reverse(array_slice($runs, 0, 20));
        if (count($points) < 2) {
            return '';
        }
        [$bar, $gap, $hgt] = [4, 1.5, 22];
        $max = max(1, ...array_map(fn (Run $r) => $r->durationMs ?? 0, $points));
        $bars = '';
        foreach ($points as $i => $r) {
            $x = Text::toFixed($i * ($bar + $gap), 1);
            if ($r->status === 'running') {
                $bars .= "<rect class=\"running\" x=\"{$x}\" y=\"" . Js::number($hgt - 6.5) . '" width="' . ($bar - 1) . '" height="6"/>';
                continue;
            }
            $tall = max($r->status === 'ok' ? 2 : 6, (($r->durationMs ?? 0) / $max) * $hgt);
            $cls = $r->status === 'ok' ? '' : ' class="bad"';
            $bars .= "<rect{$cls} x=\"{$x}\" y=\"" . Text::toFixed($hgt - $tall, 1) . "\" width=\"{$bar}\" height=\"" . Text::toFixed($tall, 1) . '" rx=".5"/>';
        }
        $w = Text::toFixed(count($points) * ($bar + $gap) - $gap, 1);
        return "<svg class=\"spark\" width=\"{$w}\" height=\"{$hgt}\" viewBox=\"0 0 {$w} {$hgt}\" aria-hidden=\"true\" focusable=\"false\">{$bars}</svg>";
    }

    private static function stamp(int|float|null $at, int|float $now): string
    {
        if ($at === null) {
            return '<span class="muted">never</span>';
        }
        $iso = Js::isoTime($at);
        if ($iso === null) {
            return '<span class="nowrap">' . Js::beyondDates($at) . '</span>';
        }
        return "<time class=\"nowrap\" datetime=\"{$iso}\" title=\"" . substr(str_replace('T', ' ', $iso), 0, 19) . ' UTC">' . Text::h(Duration::relative($at, $now)) . '</time>';
    }

    /**
     * Counts by health, the ones needing attention first; a zero is set faint
     * rather than left out, so the row keeps its shape.
     *
     * @param list<JobSummary> $jobs
     */
    private static function healthFigures(array $jobs): string
    {
        $cells = '';
        foreach (self::HEALTH as $health => [$cls, $label]) {
            $n = count(array_filter($jobs, fn (JobSummary $j) => $j->health === $health));
            $cells .= '<div class="' . ($n === 0 ? 'zero' : $cls) . "\"><dt><i class=\"sq {$cls}\" aria-hidden=\"true\"></i>{$label}</dt><dd>{$n}</dd></div>";
        }
        return "<dl class=\"figures\">{$cells}</dl>";
    }

    /**
     * The board: health figures, the last day's timeline, and a table of every job.
     *
     * @param list<JobSummary> $jobs
     * @param array<string, list<Run>> $runsByJob
     * @param list<array{job: JobSummary, runs: list<Run>, complete: bool}>|null $lanes
     * @param string|null $empty the HTML shown under the headline when there are no jobs, in place of how to declare one
     */
    public static function dashboardPage(array $jobs, array $runsByJob, int|float $now, string $base, int|float|null $checkedAt = null, ?array $lanes = null, ?\Closure $head = null, ?string $empty = null): string
    {
        $lanes ??= array_map(fn (JobSummary $job) => ['job' => $job, 'runs' => $runsByJob[$job->name] ?? [], 'complete' => true], array_slice($jobs, 0, Timeline::BOARD_LANES));
        $total = count($jobs);
        $attention = count(array_filter($jobs, fn (JobSummary $j) => $j->health !== 'healthy'));
        $headline = match (true) {
            $total === 0 => 'No jobs yet.',
            $attention === 0 => ($total === 1 ? 'The one job is' : "All {$total} jobs are") . ' healthy.',
            default => "{$total} job" . ($total === 1 ? '' : 's') . ", <b>{$attention} needing attention</b>.",
        };

        $rows = [];
        foreach ($jobs as $job) {
            $last = $job->lastRun;
            $d = $job->definition;
            $description = Text::truthy($d->get('description')) ? '<span class="desc">' . Text::h($d->get('description')) . '</span>' : '';
            $schedule = Text::truthy($d->get('schedule'))
                ? Text::h($d->get('schedule')) . (Text::truthy($d->get('timezone')) ? '<span class="tz">' . Text::h($d->get('timezone')) . '</span>' : '')
                : '<span class="muted">no schedule</span>';
            $lastCell = $last !== null
                ? self::runState($last) . ' ' . self::stamp($last->startedAt, $now) . ($last->durationMs !== null ? '<span class="sub">took ' . Text::h(Duration::format($last->durationMs)) . '</span>' : '')
                : '<span class="muted">never</span>';
            $next = $job->nextExpectedAt;
            $nextCell = $next !== null
                ? ($next < $now ? '<span class="state warn">overdue</span> ' : '') . self::stamp($next, $now) . '<span class="sub">' . Text::h(Timeline::when($next, $now)) . ' UTC</span>'
                : '<span class="muted">not scheduled</span>';
            $rows[] = "<tr>\n"
                . '<td class="job"><a class="name" href="' . Text::h($base) . '/jobs/' . Text::encodeUriComponent($job->name) . '">' . Text::name($job->name) . "</a>{$description}</td>\n"
                . '<td class="health">' . self::healthState($job) . "</td>\n"
                . "<td class=\"nowrap hide-sm\">{$schedule}</td>\n"
                . "<td class=\"nowrap last\">{$lastCell}</td>\n"
                . "<td class=\"nowrap hide-sm\">{$nextCell}</td>\n"
                . '<td class="hide-sm">' . self::sparkline($runsByJob[$job->name] ?? []) . "</td>\n"
                . '</tr>';
        }

        $span = ['from' => $now - Timeline::BOARD_BEHIND_MS, 'to' => $now + Timeline::BOARD_AHEAD_MS, 'now' => $now];
        $checked = $checkedAt ? ', checked ' . Text::h(Duration::relative($checkedAt, $now)) : '';
        $figures = $total > 0
            ? self::healthFigures($jobs)
            : '<p class="empty">' . ($empty ?? 'Declare one with <code>' . Text::h(self::DECLARE_ONE) . '</code> and run it once, and it shows up here.') . '</p>';
        $sections = $total > 0
            ? "<section class=\"sec\" aria-label=\"Last 24 hours\">\n"
                . "  <h2>Last 24 hours</h2>\n"
                . "  <p class=\"lede\">One lane per job. Faint ticks mark when it was due, bars the runs it recorded, as long as they took. A dashed box is a slot nothing ran in. Times are UTC.</p>\n"
                . '  <div class="wide">' . Timeline::dayTimeline($lanes, $span, $base, $total) . "</div>\n"
                . "</section>\n"
                . "<section class=\"sec\" aria-label=\"Jobs\">\n"
                . "  <h2>Jobs</h2>\n"
                . "  <p class=\"lede\">Every job in the store. Open one for its week, its runs, and their output.</p>\n"
                . "  <div class=\"wide\"><table class=\"board\">\n"
                . "<thead><tr><th>Job</th><th>Health</th><th class=\"hide-sm\">Schedule</th><th>Last run</th><th class=\"hide-sm\">Next due</th><th class=\"hide-sm\">Recent runs</th></tr></thead>\n"
                . '<tbody>' . implode("\n", $rows) . "</tbody></table></div>\n"
                . '</section>'
            : '';
        $b = Text::h($base);
        $body = "\n<header class=\"top\">\n"
            . '  ' . self::brand($base) . "\n"
            . "  <div class=\"actions\">\n"
            . '    <span class="meta">' . Text::h(Timeline::clock($now)) . " UTC{$checked}</span>\n"
            . "    <form class=\"inline\" method=\"post\" action=\"{$b}/check\"><button class=\"primary\" type=\"submit\">Run check now</button></form>\n"
            . "  </div>\n"
            . "</header>\n"
            . "<main>\n"
            . "<section class=\"sec\" aria-label=\"Health\">\n"
            . "  <h2>Health</h2>\n"
            . "  <div>\n"
            . "    <p class=\"headline\">{$headline}</p>\n"
            . "    {$figures}\n"
            . "  </div>\n"
            . "</section>\n"
            . "{$sections}\n"
            . "</main>\n"
            . "<footer><span>Refreshes every minute. Times are UTC.</span><a href=\"{$b}/api/jobs\">JSON</a><a class=\"version\" href=\"https://github.com/cronwatchdev/cronwatch/blob/main/CHANGELOG.md\">cronwatch/cronwatch " . \Cronwatch\Cronwatch::VERSION . '</a></footer>';
        return self::layout('CronWatch', $body, $base, 60, $head);
    }

    /**
     * One job: its state and figures, its last seven days, its runs with
     * their output, and its definition. `complete` is false when `runs` does
     * not reach back over the whole week (the run list shows the newest fifty).
     *
     * @param list<Run> $runs
     */
    public static function jobPage(JobSummary $job, array $runs, int|float $now, string $base, bool $complete = true, ?\Closure $head = null): string
    {
        $d = $job->definition;
        $stats = $job->stats;
        $okRate = Js::number(Js::round($stats['okRate'] * 100)) . '%';
        $listed = array_slice($runs, 0, 50);
        $runRows = [];
        foreach ($listed as $run) {
            $detail = (Text::truthy($run->error) ? '<details class="out error" open><summary>error</summary><pre>' . Text::h($run->error) . '</pre></details>' : '')
                . (Text::truthy($run->output) ? '<details class="out"' . ($run->status === 'ok' ? '' : ' open') . '><summary>output</summary><pre>' . Text::h($run->output) . '</pre></details>' : '');
            $metrics = '';
            foreach (Text::entries($run->metrics) as [$key, $value]) {
                // A foreign row may hold a metric that is no finite number (null, text); it is left out.
                if (!Js::isFinite($value)) {
                    continue;
                }
                $metrics .= '<span><span class="k">' . Text::h($key) . '</span> ' . Text::h(Js::isInteger($value) ? $value : Text::toFixed($value, 4)) . '</span>';
            }
            $runRows[] = '<tr' . ($detail !== '' ? ' class="has-detail"' : '') . ">\n"
                . '<td class="nowrap">' . self::runState($run) . "</td>\n"
                . '<td class="nowrap">' . Text::h(Timeline::when($run->startedAt, $now)) . ' <span class="muted">UTC</span><span class="sub">' . self::stamp($run->startedAt, $now) . "</span></td>\n"
                . '<td class="nowrap">' . ($run->durationMs !== null ? Text::h(Duration::format($run->durationMs)) : '<span class="muted">running</span>') . "</td>\n"
                . '<td class="hide-sm">' . ($metrics !== '' ? "<span class=\"metrics\">{$metrics}</span>" : '') . "</td>\n"
                . '<td class="hide-sm muted">' . Text::h($run->trigger) . "</td>\n"
                . '</tr>' . ($detail !== '' ? "<tr class=\"detail\"><td colspan=\"5\">{$detail}</td></tr>" : '');
        }

        $silenced = $job->silencedUntil !== null && $job->silencedUntil > $now;
        $path = Text::h($base) . '/jobs/' . Text::encodeUriComponent($job->name);
        $parsed = Timeline::parsedSchedule($job);
        $why = Timeline::laneNote($job, Timeline::missedAt($job, $parsed, [], $now), $now);
        $silenceForm = $silenced
            ? "<form class=\"inline\" method=\"post\" action=\"{$path}/unsilence\"><button type=\"submit\">Unsilence (until " . Text::h(Duration::relative($job->silencedUntil, $now)) . ')</button></form>'
            : "<details class=\"confirm\"><summary>Silence</summary><form class=\"inline\" method=\"post\" action=\"{$path}/silence\"><span>for</span> <button type=\"submit\" name=\"for\" value=\"1h\">1 hour</button><button type=\"submit\" name=\"for\" value=\"4h\">4 hours</button><button type=\"submit\" name=\"for\" value=\"1d\">1 day</button><button type=\"submit\" name=\"for\" value=\"7d\">1 week</button></form></details>";

        $schedule = Text::truthy($d->get('schedule'))
            ? Text::h($d->get('schedule')) . (Text::truthy($d->get('timezone')) ? ' <span class="muted">' . Text::h($d->get('timezone')) . '</span>' : '')
            : '<span class="muted">none</span>';
        $budget = '';
        if (Text::truthy($d->get('budget'))) {
            $limits = array_map(fn (array $entry) => "{$entry[0]} \u{2264} " . Text::text($entry[1]), Text::entries($d->get('budget')));
            $budget = '<dt>Budget</dt><dd>' . Text::h(implode(', ', $limits)) . '</dd>';
        }
        $floor = '';
        if (Text::truthy($d->get('floor'))) {
            $limits = array_map(fn (array $entry) => "{$entry[0]} \u{2265} " . Text::text($entry[1]), Text::entries($d->get('floor')));
            $floor = '<dt>Floor</dt><dd>' . Text::h(implode(', ', $limits)) . '</dd>';
        }
        $failures = $d->get('failuresBeforeAlert');
        $alertAfter = Text::truthy($failures) && Js::isNumber($failures) && $failures > 1 ? '<dt>Alert after</dt><dd>' . Text::h($failures) . ' consecutive failures</dd>' : '';
        $tags = $d->get('tags');
        $tagList = is_array($tags) && $tags !== [] ? '<dt>Tags</dt><dd>' . implode(', ', array_map(fn ($t) => Text::h($t), $tags)) . '</dd>' : '';
        $open = '';
        foreach ($job->open as $condition) {
            $open .= '<span class="state ' . ($condition === 'failed' || $condition === 'stuck' ? 'bad' : 'warn') . '">' . Text::h(self::spaced($condition)) . '</span>';
        }
        $openList = $job->open !== [] ? "<dt>Open</dt><dd>{$open}</dd>" : '';
        $inARow = $job->consecutiveFailures > 0 ? '<dt>Failures in a row</dt><dd>' . Text::h($job->consecutiveFailures) . '</dd>' : '';
        $maxDuration = Text::truthy($d->get('maxDuration')) ? '<dt>Max duration</dt><dd>' . Text::h($d->get('maxDuration')) . '</dd>' : '';
        $expect = Text::truthy($d->get('expect')) ? '<dt>Expect</dt><dd>' . Text::h($d->get('expect')) . '</dd>' : '';
        $description = Text::truthy($d->get('description')) ? '<p class="desc">' . Text::h($d->get('description')) . '</p>' : '';
        $whyNote = $why !== null && $why !== '' ? '<span class="why">' . Text::h($why) . '</span>' : '';
        $lastRun = $job->lastRun !== null ? Text::h(Duration::relative($job->lastRun->startedAt, $now)) : 'never';
        $nextDue = $job->nextExpectedAt !== null ? Text::h(Duration::relative($job->nextExpectedAt, $now)) : '<small>no schedule</small>';
        $p50 = $stats['p50Ms'] !== null ? Text::h(Duration::format($stats['p50Ms'])) : '?';
        $p95 = $stats['p95Ms'] !== null ? Text::h(Duration::format($stats['p95Ms'])) : '?';
        $count = count($listed);
        $runsSection = $count === 0
            ? '<p class="lede">No runs yet.</p>'
            : '<p class="lede">The newest ' . ($count === 1 ? 'run' : "{$count} runs") . ", with any error and output.</p>\n"
                . "  <div class=\"wide\"><table class=\"runs\">\n"
                . "<thead><tr><th>Status</th><th>Started</th><th>Took</th><th class=\"hide-sm\">Metrics</th><th class=\"hide-sm\">Trigger</th></tr></thead>\n"
                . '<tbody>' . implode("\n", $runRows) . '</tbody></table></div>';
        $b = Text::h($base);

        $body = "\n<header class=\"top\">\n"
            . '  ' . self::brand($base, $job->name) . "\n"
            . '  <div class="actions"><span class="meta">' . Text::h(Timeline::clock($now)) . " UTC</span></div>\n"
            . "</header>\n"
            . "<main>\n"
            . "<section class=\"sec intro\" aria-label=\"Job\">\n"
            . "  <h2>Job</h2>\n"
            . "  <div>\n"
            . '    <h1 class="jobname">' . Text::name($job->name) . "</h1>\n"
            . "    {$description}\n"
            . '    <p class="stateline">' . self::healthState($job) . "{$whyNote}</p>\n"
            . "    <div class=\"actions\">\n"
            . "      {$silenceForm}\n"
            . "    </div>\n"
            . "    <dl class=\"figures\">\n"
            . "      <div><dt>Last run</dt><dd>{$lastRun}</dd></div>\n"
            . "      <div><dt>Next due</dt><dd>{$nextDue}</dd></div>\n"
            . '      <div><dt>Success, last ' . Text::h($stats['runs']) . '</dt><dd>' . Text::h($okRate) . "</dd></div>\n"
            . "      <div><dt>p50 / p95</dt><dd>{$p50} <small>/ {$p95}</small></dd></div>\n"
            . "    </dl>\n"
            . "  </div>\n"
            . "</section>\n"
            . "<section class=\"sec\" aria-label=\"Last 7 days\">\n"
            . "  <h2>Last 7 days</h2>\n"
            . "  <p class=\"lede\">A lane per UTC day, today first. Faint ticks mark when the job was due, bars its runs, as long as they took.</p>\n"
            . '  <div class="wide">' . Timeline::weekTimeline($job, $runs, $complete, $now) . "</div>\n"
            . "</section>\n"
            . "<section class=\"sec\" aria-label=\"Runs\">\n"
            . "  <h2>Runs</h2>\n"
            . "  {$runsSection}\n"
            . "</section>\n"
            . "<section class=\"sec\" aria-label=\"Definition\">\n"
            . "  <h2>Definition</h2>\n"
            . "  <dl class=\"def\">\n"
            . "  <dt>Schedule</dt><dd>{$schedule}</dd>\n"
            . '  <dt>Grace</dt><dd>' . Text::h($d->get('grace') ?? '10m') . "</dd>\n"
            . '  <dt>Timeout</dt><dd>' . Text::h($d->get('timeout') ?? '1h') . "</dd>\n"
            . "  {$maxDuration}\n"
            . "  {$budget}\n"
            . "  {$floor}\n"
            . "  {$expect}\n"
            . "  {$alertAfter}\n"
            . "  {$tagList}\n"
            . "  {$openList}\n"
            . "  {$inARow}\n"
            . "  </dl>\n"
            . "</section>\n"
            . "<section class=\"sec delete\" aria-label=\"Delete\">\n"
            . "  <h2>Delete</h2>\n"
            . "  <div>\n"
            . "  <p class=\"lede\">Removes this job and all its runs from the store, which cannot be undone. A job still in your code comes back on its next run, with no history.</p>\n"
            . "  <details class=\"confirm\"><summary>Delete history</summary><form class=\"inline\" method=\"post\" action=\"{$path}/forget\"><span>Delete this job and all its runs?</span> <button class=\"danger\" type=\"submit\">Delete</button><a class=\"button\" href=\"{$path}\">Cancel</a></form></details>\n"
            . "  </div>\n"
            . "</section>\n"
            . "</main>\n"
            . "<footer><span>Refreshes every minute. Times are UTC.</span><a href=\"{$b}/api/jobs/" . Text::encodeUriComponent($job->name) . '">JSON</a><a class="version" href="https://github.com/cronwatchdev/cronwatch/blob/main/CHANGELOG.md">cronwatch/cronwatch ' . \Cronwatch\Cronwatch::VERSION . '</a></footer>';
        return self::layout("{$job->name}: CronWatch", $body, $base, 60, $head);
    }

    /**
     * A page with one message. With `signIn`, a form under it posts the
     * token to <base>/signin in the body, keeping it out of the URL and
     * access logs, and the routes set the cookie: the way in where there is no address bar to open a link with, such as
     * an app on an iPhone's home screen, which keeps its cookies apart from
     * Safari's.
     */
    public static function messagePage(string $title, string $message, string $base, bool $signIn = false, ?\Closure $head = null): string
    {
        $form = $signIn
            ? '<form class="signin" method="post" action="' . Text::h($base) . '/signin"><label for="token">Token</label><input id="token" name="token" type="password" autocomplete="current-password" autocapitalize="off" spellcheck="false" required><button class="primary" type="submit">Sign in</button></form>'
            : '';
        return self::layout($title, '<header class="top">' . self::brand($base) . '</header><main class="message"><h1>' . Text::h($title) . '</h1><p>' . Text::h($message) . "</p>{$form}</main>", $base, null, $head);
    }
}
