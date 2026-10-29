<?php
// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 WebTigers. Tiger™ and WebTigers™ are trademarks of WebTigers.
//
// Give a fresh evaluation install a home page.
//
// Bare core serves a BLANK home by design — <main> with nothing inside it. ComingSoon normally
// covers that gap and this image deliberately does not install it (a placeholder is not what
// someone came to look at), so without this an evaluator sees a white screen that reads as broken.
//
// Runs on a FRESH install only; an adopted install keeps whatever its owner put there. Idempotent:
// a `welcome` page that already exists is left alone.

define('APPLICATION_ROOT', getenv('TIGER_APP_ROOT') ?: '/var/www/tiger');
require APPLICATION_ROOT . '/vendor/autoload.php';
(new Tiger_Application(APPLICATION_ROOT))->boot();

$pages = new Tiger_Model_Page();
if ($pages->resolveBySlug('welcome', null, null, Tiger_Model_Page::TYPE_PAGE)) {
    echo "welcome page already exists\n";
    exit(0);
}

$body = <<<'HTML'
<div class="container py-5">
    <h1 class="fw-bold mb-3">Tiger is running.</h1>
    <p class="lead text-secondary mb-4">This is a real Tiger install in a container — the same
        framework that runs on a VPS or a shared host, not a demo.</p>
    <p class="mb-4"><a class="btn btn-primary btn-lg" href="/admin">Open the Dashboard</a></p>
    <p class="text-secondary mb-0">Edit or replace this page in the Dashboard under
        <strong>Content &rsaquo; Pages</strong>. For a one-time sign-in link that needs no password,
        run <code>docker exec &lt;container&gt; tiger-login</code>.</p>
</div>
HTML;

$row = $pages->createRow([
    'page_id' => Tiger_Uuid::v7(),
    'slug'    => 'welcome',
    'page_key'=> 'welcome',
    'title'   => 'Welcome',
    'type'    => 'page',
    'format'  => 'html',
    'status'  => 'published',
    'locale'  => 'en',
    'body'    => $body,
]);
$row->save();

// The key is tiger.SITE.home_page (Cms_Service_Settings writes it; Cms_Service_Paths documents the
// accepted shapes: '' | /path | @theme:key | a page UUID). Not tiger.cms.home_page — that one is
// silently ignored and leaves the home blank.
(new Tiger_Model_Config())->set(Tiger_Model_Config::SCOPE_GLOBAL, '', 'tiger.site.home_page', (string) $row->page_id);

echo "seeded welcome page {$row->page_id} and set it as the home\n";
