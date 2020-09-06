#!/usr/bin/env python3

# NOTE: Alphabetical order please
from os import abort, path
from bibtexparser.bwriter import BibTexWriter
from bs4 import BeautifulSoup
from citationkeys.bib  import *
from citationkeys.misc import *
from citationkeys.tags import *
from citationkeys.urlhandlers import *
from datetime import datetime
from fake_useragent import UserAgent
from http.cookiejar import CookieJar
from pathlib import Path
from pprint import pprint
from urllib.parse import urlparse, urlunparse
from urllib.request import Request

# NOTE: Alphabetical order please
import appdirs
import bibtexparser
import bs4
import click
import configparser
import glob
import os
import pyperclip
import random
import re
import subprocess
import shutil
import string
import sys
import traceback
import urllib

class AliasedGroup(click.Group):
    def get_command(self, ctx, cmd_name):
        rv = click.Group.get_command(self, ctx, cmd_name)
        if rv is not None:
            return rv

        matches = [x for x in self.list_commands(ctx)
                   if x.startswith(cmd_name)]

        if not matches:
            return None
        elif len(matches) == 1:
            return click.Group.get_command(self, ctx, matches[0])

        ctx.fail('Too many matches: %s' % ', '.join(sorted(matches)))

#@click.group(invoke_without_command=True)
@click.group(cls=AliasedGroup)
@click.option(
    '-c', '--config-file',
    default=os.path.join(appdirs.user_config_dir('ck'), 'ck.config'),
    help='Path to ck config file.'
    )
@click.option(
    '-v', '--verbose',
    count=True,
    help='Pass multiple times for extra detail.'
    )
@click.pass_context
def ck(ctx, config_file, verbose):
    if ctx.invoked_subcommand is None:
        click.echo('I was invoked without subcommand, listing bibliography...')
        notimplemented()
        click.echo('Call with --help for usage.')

    #click.echo("I am about to invoke '%s' subcommand" % ctx.invoked_subcommand)

    # read configuration
    if verbose > 0:
        click.echo("Verbosity level: " + str(verbose))
        click.echo("Reading CK config file at " + config_file)

        if verbose > 1:
            if os.path.exists(config_file):
                print(file_to_string(config_file).strip())
            else:
                click.secho("ERROR: CK config file does not exist", fg="red")

    config = configparser.ConfigParser()
    with open(config_file, 'r') as f:
        config.read_file(f)

    if verbose > 2:
        print("Configuration sections:", config.sections())

    # set a context with various config params that we pass around to the subcommands
    ctx.ensure_object(dict)
    ctx.obj['verbosity']      = verbose
    ctx.obj['BibDir']         = config['default']['BibDir']
    ctx.obj['TagDir']         = config['default']['TagDir']
    ctx.obj['TextEditor']     = config['default']['TextEditor']
    ctx.obj['MarkdownEditor'] = config['default']['MarkdownEditor']
    ctx.obj['tags']           = find_tagged_pdfs(ctx.obj['TagDir'], verbose)

    # set command to open PDFs with
    if sys.platform.startswith('linux'):
        ctx.obj['OpenCmd'] = 'xdg-open'
    elif sys.platform == 'darwin':
        ctx.obj['OpenCmd'] = 'open'
    else:
        click.secho("ERROR: " + sys.platform + " is not supported", fg="red", err=True)
        sys.exit(1)

    # always do a sanity check before invoking the actual subcommand
    # TODO: figure out how to call this *after* (not before) the subcommand is invoked, so the user can actually see its output
    #ck_check(ctx.obj['BibDir'], ctx.obj['TagDir'], verbose)

@ck.command('check')
@click.pass_context
def ck_check_cmd(ctx):
    """Checks the BibDir and TagDir for integrity."""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    ck_check(ck_bib_dir, ck_tag_dir, verbosity)

def ck_check(ck_bib_dir, ck_tag_dir, verbosity):
    # find PDFs without bib files (and viceversa)
    missing = {}
    missing['.pdf'] = []
    missing['.bib'] = []
    counterpart_ext = {}
    counterpart_ext['.pdf'] = '.bib'
    counterpart_ext['.bib'] = '.pdf'

    extensions = missing.keys()
    for ck in list_cks(ck_bib_dir):
        for ext in extensions:
            filepath = os.path.join(ck_bib_dir, ck + ext)

            if verbosity > 1:
                print("Checking", filepath)

            counterpart = os.path.join(ck_bib_dir, ck + counterpart_ext[ext])

            if not os.path.exists(counterpart):
                missing[counterpart_ext[ext]].append(ck)

    for ext in [ '.pdf', '.bib' ]:
        if len(missing[ext]) > 0:
            print("Papers with missing " + ext + " files:")
            print("------------------------------")

        missing[ext].sort()
        for f in missing[ext]:
            print(" - " + f)

        if len(missing[ext]) > 0:
            print()
        
    # make sure all .pdf extensions are lowercase in TagDir
    for relpath in os.listdir(ck_tag_dir):
        filepath = os.path.join(ck_tag_dir, relpath)
        ck, extOrig = os.path.splitext(relpath)
        
        ext = extOrig.lower()
        if ext != extOrig:
            print("WARNING:", filepath, "has uppercase", "." + extOrig, "extension in TagDir")
    
    # TODO: make sure symlinks are not broken in TagDir
    # TODO: make sure all .bib files have the right CK and have ckdateadded

def abort_citation_exists(ctx, destpdffile, citation_key):
    click.secho("ERROR: " + destpdffile + " already exists. Pick a different citation key.", fg="red", err=True)
    if click.confirm("\nWould you like to tag the existing paper?", default=True):
        ctx.invoke(ck_tags_cmd)
        print()
        # prompt user to tag paper
        ctx.invoke(ck_tag_cmd, citation_key=citation_key)

@ck.command('add')
@click.argument('url', required=True, type=click.STRING)
@click.argument('citation_key', required=False, type=click.STRING)
@click.option(
    '-n', '--no-tag-prompt',
    is_flag=True,
    default=False,
    help='Does not prompt the user to tag the paper.'
    )
@click.option(
    '-c', '--no-rename-ck',
    is_flag=True,
    default=False,
    help='Does not rename the CK in the .bib file.'
    )
@click.option(
    '-b', '--keep-bibtex-id',
    is_flag=True,
    default=False,
    help='Keep the id from the .bib file.'
)
@click.pass_context
def ck_add_cmd(ctx, url, citation_key, no_tag_prompt, no_rename_ck, keep_bibtex_id):
    """Adds the paper to the library (.pdf and .bib file)."""

    # TODO: come up with CK automatically if not specified & make sure it's unique (unclear how to handle eprint version of the same paper)

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    if verbosity > 0:
        print("Verbosity:", verbosity)

    # Make sure paper doesn't exist in the library first
    # TODO: save to temp file, so you can first display abstract with author names and prompt the user for the "Citation Key" rather than giving it as an arg
    tmpCK = False
    if not citation_key:
        citation_key = 'TMP' + ''.join(random.sample(string.ascii_lowercase, 8))
        tmpCK = True

    destpdffile = ck_to_pdf(ck_bib_dir, citation_key)
    destbibfile = ck_to_bib(ck_bib_dir, citation_key)

    parsed_url = urlparse(url)
    if verbosity > 0:
        print("Paper's URL:", parsed_url)

    # TODO: change to regex matching
    # TODO: incorporate zotero translators
    # get domain of website and handle it accordingly
    handlers = dict()
    handlers["link.springer.com"] = springerlink_handler
    handlers["arxiv.org"] = arxiv_handler
    handlers["rd.springer.com"] = springerlink_handler
    handlers["eprint.iacr.org"]   = iacreprint_handler
    handlers["dl.acm.org"]        = dlacm_handler
    # e.g., https://epubs.siam.org/doi/abs/10.1137/S0036144502417715
    handlers["epubs.siam.org"] = epubssiam_handler
    handlers["ieeexplore.ieee.org"] = ieeexplore_handler
    handlers["www.sciencedirect.com"] = sciencedirect_handler
    handlers["sciencedirect.com"] = handlers["www.sciencedirect.com"]

    no_index_html = dict()
    no_index_html["eprint.iacr.org"] = True

    domain = parsed_url.netloc
    cj = CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    user_agent = UserAgent().random
    parser = "lxml"

    pdf_data = None
    bib_data = None

    if domain in handlers:

        soup = None
        index_html = None
        # e.g., we never download the index page for IACR ePrint
        if domain not in no_index_html or no_index_html[domain] == False:
            index_html = get_url(opener, url, verbosity, user_agent)
            soup = BeautifulSoup(index_html, parser)

        handler = handlers[domain]
        # TODO: display abstract
        # TODO: if no CK specified, prompt the user for one
        bib_data, pdf_data = handler(opener, soup, parsed_url, ck_bib_dir, parser, user_agent, verbosity)

    else:
        click.echo("No handler for URL was found. Trying to download as PDF...")
        pdf_data = download_pdf(opener, user_agent, url, verbosity)

        if True:   #not os.path.exists(destbibfile):
            # TODO: try pre-fill something here
            # guess from the pdf file
            bibtex = bib_new(citation_key, "misc")
            bibtex.entries[0]['howpublished'] = '\\url{' + url + '}'
            bibtex.entries[0]['author'] = ''
            bibtex.entries[0]['year'] = ''
            bibtex.entries[0]['title'] = ''
            now = datetime.now()
            timestr = now.strftime("%Y-%m-%d %H:%M:%S")
            bibtex.entries[0]['ckdateadded'] = timestr
            bib_data = bib_serialize(bibtex)
            bib_data = click.edit(bib_data, ctx.obj['TextEditor']).encode('utf-8') # external editor

    if tmpCK:
            bib_entry = defaultdict(lambda : '', bib_deserialize(bib_data.decode()).entries[0])
            if keep_bibtex_id and 'ID' in bib_entry:
                no_rename_ck = True
                citation_key = bib_entry['ID']
            else:
                suggested = bib_suggest_citation_key(bib_entry)
                if suggested: # the user might enter nothing
                    citation_key = suggested
            click.secho('Using citation key %s' % citation_key, fg="yellow")

            destpdffile = ck_to_pdf(ck_bib_dir, citation_key)
            destbibfile = ck_to_bib(ck_bib_dir, citation_key)
    
    if os.path.exists(destpdffile):
        abort_citation_exists(ctx, destpdffile, citation_key)
        sys.exit(1)
    
    if (domain in handlers) and os.path.exists(destbibfile):
        # when downloading just the PDF, we shouldn't care if a .bib file already exists
        abort_citation_exists(ctx, destbibfile, citation_key)
        sys.exit(1)
    
    with open(destpdffile, 'wb') as fout_pdf:
        fout_pdf.write(pdf_data)

    # we might already have a bib file for this, so don't overwrite it if we do
    if not os.path.exists(destbibfile):
        with open(destbibfile, 'wb') as fout_bib:
            fout_bib.write(bib_data)

    if not no_rename_ck:
        # TODO: inefficient, reading bibfile multiple times
        # change the citation key in the .bib file to citation_key
        bib_rename_ck(destbibfile, citation_key)

        # update ckdateadded
        bib_set_dateadded(destbibfile, None)

    if not no_tag_prompt:
        # display all tags 
        ctx.invoke(ck_tags_cmd)

        print()

        # prompt user to tag paper
        ctx.invoke(ck_tag_cmd, citation_key=citation_key)

@ck.command('config')
@click.pass_context
def ck_config_cmd(ctx):
    """Lets you edit the config file and prints it at the end."""

    ctx.ensure_object(dict)
    ck_text_editor = ctx.obj['TextEditor']

    fullpath = os.path.join(appdirs.user_config_dir('ck'), 'ck.config')
    os.system(ck_text_editor + " \"" + fullpath + "\"")

@ck.command('queue')
@click.argument('citation_key', required=False, type=click.STRING)
@click.pass_context
def ck_queue_cmd(ctx, citation_key):
    """Marks this paper as 'to-be-read', removing the 'queue/reading' and/or 'queue/finished' tags"""
    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    if citation_key is not None:
        ctx.invoke(ck_tag_cmd, silent=True, citation_key=citation_key, tags="queue/to-read")
        ctx.invoke(ck_untag_cmd, silent=True, citation_key=citation_key, tags="queue/finished,queue/reading")
    else:
        click.secho("Papers that remain to be read:", bold=True)
        click.echo()

        ctx.invoke(ck_list_cmd, pathnames=[os.path.join(ck_tag_dir, 'queue/to-read')])

@ck.command('dequeue')
@click.argument('citation_key', required=True, type=click.STRING)
@click.pass_context
def ck_dequeue_cmd(ctx, citation_key):
    """Removes this paper from the to-read list"""
    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    ctx.invoke(ck_untag_cmd, silent=True, citation_key=citation_key, tags="queue/to-read")

@ck.command('read')
@click.argument('citation_key', required=False, type=click.STRING)
@click.pass_context
def ck_read_cmd(ctx, citation_key):
    """Marks this paper as in the process of 'reading', removing the 'queue/to-read' and/or 'queue/finished' tags"""
    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    if citation_key is not None:
        ctx.invoke(ck_untag_cmd, silent=True, citation_key=citation_key, tags="queue/to-read,queue/finished")
        ctx.invoke(ck_tag_cmd, silent=True, citation_key=citation_key, tags="queue/reading")
        ctx.invoke(ck_open_cmd, filename=citation_key + ".pdf")
    else:
        click.secho("Papers you are currently reading:", bold=True)
        click.echo()

        ctx.invoke(ck_list_cmd, pathnames=[os.path.join(ck_tag_dir, 'queue/reading')])

@ck.command('finished')
@click.argument('citation_key', required=False, type=click.STRING)
@click.pass_context
def ck_finished_cmd(ctx, citation_key):
    """Marks this paper as 'finished reading', removing the 'queue/to-read' and/or 'queue/reading' tags"""
    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    if citation_key is not None:
        ctx.invoke(ck_untag_cmd, silent=True, citation_key=citation_key, tags="queue/to-read,queue/reading")
        ctx.invoke(ck_tag_cmd, silent=True, citation_key=citation_key, tags="queue/finished")
    else:
        click.secho("Papers you have finished reading:", bold=True)
        click.echo()

        ctx.invoke(ck_list_cmd, pathnames=[os.path.join(ck_tag_dir, 'queue/finished')])

@ck.command('untag')
@click.option(
    '-f', '--force',
    is_flag=True,
    default=False,
    help='Do not prompt for confirmation when removing all tags')
@click.option(
    '-s', '--silent',
    is_flag=True,
    default=False,
    help='Does not display error message when paper was not tagged.')
@click.argument('citation_key', required=False, type=click.STRING)
@click.argument('tags', required=False, type=click.STRING)
@click.pass_context
def ck_untag_cmd(ctx, force, silent, citation_key, tags):
    """Untags the specified paper."""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags    = ctx.obj['tags']
        
    if citation_key is None and tags is None:
        # If no paper was specified, detects untagged papers and asks the user to tag them.
        untagged_pdfs = find_untagged_pdfs(ck_bib_dir, ck_tag_dir, list_cks(ck_bib_dir), ck_tags.keys(), verbosity)
        if len(untagged_pdfs) > 0:
            sys.stdout.write("Untagged papers:\n")
            for (filepath, citation_key) in untagged_pdfs:
                # display paper info
                ctx.invoke(ck_info_cmd, citation_key=citation_key)
            click.echo()

            for (filepath, citation_key) in untagged_pdfs:
                # display all tags 
                ctx.invoke(ck_tags_cmd)
                # prompt user to tag paper
                ctx.invoke(ck_tag_cmd, citation_key=citation_key)
        else:
            click.echo("No untagged papers.")
    else:
        if tags is not None:
            tags = parse_tags(tags)
            for tag in tags:
                if untag_paper(ck_tag_dir, citation_key, tag):
                    click.secho("Removed '" + tag + "' tag", fg="green")
                else:
                    # When invoked by ck_{queue/read/finished}_cmd, we want this silenced
                    if not silent:
                        click.secho("Was not tagged with '" + tag + "' tag to begin with", fg="red", err=True)
        else:
            if force or click.confirm("Are you sure you want to remove ALL tags for " + click.style(citation_key, fg="blue") + "?"):
                if untag_paper(ck_tag_dir, citation_key):
                    click.secho("Removed all tags!", fg="green")
                else:
                    click.secho("No tags to remove.", fg="red")

@ck.command('info')
@click.argument('citation_key', required=True, type=click.STRING)
@click.pass_context
def ck_info_cmd(ctx, citation_key):
    """Displays info about the specified paper"""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags    = ctx.obj['tags']

    include_url = True
    print_ck_tuples(cks_to_tuples(ck_bib_dir, [ citation_key ], verbosity), ck_tags, include_url)

@ck.command('tags')
@click.pass_context
def ck_tags_cmd(ctx):
    """Lists all tags in the library"""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags    = ctx.obj['tags']

    print_all_tags(ck_tag_dir)

# TODO: use git-annex to manage tags
# TODO: make symbol links working for multiple machines
@ck.command('tag')
@click.option(
    '-s', '--silent',
    is_flag=True,
    default=False,
    help='Does not display error message when paper is already tagged.')
@click.argument('citation_key', required=True, type=click.STRING)
@click.argument('tags', required=False, type=click.STRING)
@click.pass_context
def ck_tag_cmd(ctx, silent, citation_key, tags):
    """Tags the specified paper"""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags    = ctx.obj['tags']

    #if not silent:
    #    click.echo("Tagging '" + style_ck(citation_key) + "' with " + style_tags(tags) + "...")

    ctx.invoke(ck_info_cmd, citation_key=citation_key)

    if not ck_exists(ck_bib_dir, citation_key):
        click.secho("ERROR: " + citation_key + " has no PDF file", fg="red", err=True)
        sys.exit(1)

    if tags is None:
        probe_pdfgrep = subprocess.check_output('which pdfgrep', shell=True).decode()
        if 'not found' in probe_pdfgrep:
            click.secho("Installing pdfgrep can allow me to make tag suggestions.", fg='cyan')
            click.secho("\t sudo apt install pdfgrep", fg='cyan')
        else:
            # analyze pdf for tags
            tags = get_all_tags(ck_tag_dir)
            suggested_tags = []
            click.secho("Generating suggested tags..", fg='cyan')
            tag_extended_regex = '|'.join([ r'\b{}\b'.format(t) for t in tags])
            try:
                ret = subprocess.check_output("pdfgrep '%s' %s" % (tag_extended_regex, ck_to_pdf(ck_bib_dir, citation_key)), shell=True).decode()
            except subprocess.CalledProcessError:
                ret = ''
            for tag in tags:
                if tag in ret: # count only non-zero
                    suggested_tags.append((tag, ret.count(tag)))
            suggested_tags = sorted(suggested_tags, key=lambda x: x[1], reverse=True)
            click.secho("Suggested: " + ','.join([x[0] for x in suggested_tags]), fg="cyan")
        # returns array of tags
        tags = prompt_for_tags(ctx, "Please enter tag(s) for '" + click.style(citation_key, fg="blue") + "'")
    else:
        # parses comma-separated tag string into an array of tags
        tags = parse_tags(tags)

    for tag in tags:
        if tag_paper(ck_tag_dir, ck_bib_dir, citation_key, tag):
            click.secho("Added '" + tag + "' tag", fg="green")
        else:
            # When invoked by ck_{queue/read/finished}_cmd, we want this silenced
            if not silent:
                click.secho(citation_key + " already has '" + tag + "' tag", fg="red", err=True)

@ck.command('rm')
@click.option(
    '-f', '--force',
    is_flag=True,
    default=False,
    help='Do not prompt for confirmation before deleting'
    )
@click.argument('citation_key', required=True, type=click.STRING)
@click.pass_context
def ck_rm_cmd(ctx, force, citation_key):
    """Removes the paper from the library (.pdf and .bib file). Can provide citation key or filename with .pdf or .bib extension."""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    
    # allow user to provide file name directly (or citation key to delete everything)
    basename, extension = os.path.splitext(citation_key)

    if len(extension.strip()) > 0:
        files = [ os.path.join(ck_bib_dir, citation_key) ]
    else:
        files = [ ck_to_pdf(ck_bib_dir, citation_key), ck_to_bib(ck_bib_dir, citation_key) ]

    something_to_del = False
    for f in files:
        if os.path.exists(f):
            something_to_del = True

    if force or something_to_del:
        if not force:
            if not click.confirm("Are you sure you want to delete '" + citation_key + "' from the library?"):
                click.echo("Okay, not deleting anything.")
                return

        for f in files:
            if os.path.exists(f):
                os.remove(f)
                click.secho("Deleted " + f, fg="green")
            else:
                click.secho("WARNING: " + f + " does not exist, nothing to delete...", fg="red", err=True)

        # untag the paper
        untag_paper(ck_tag_dir, citation_key)
    else:
        click.echo(citation_key + " is not in library. Nothing to delete.")

@ck.command('open')
@click.argument('filename', required=True, type=click.STRING)
@click.pass_context
def ck_open_cmd(ctx, filename):
    """Opens the .pdf or .bib file."""

    ctx.ensure_object(dict)
    verbosity          = ctx.obj['verbosity']
    ck_bib_dir         = ctx.obj['BibDir']
    ck_tag_dir         = ctx.obj['TagDir']
    ck_open            = ctx.obj['OpenCmd']
    ck_text_editor     = ctx.obj['TextEditor']
    ck_markdown_editor = ctx.obj['MarkdownEditor']
    ck_tags            = ctx.obj['tags']

    citation_key, extension = os.path.splitext(filename)

    if len(extension.strip()) == 0:
        filename = citation_key + ".pdf"
        extension = '.pdf'
        
    fullpath = os.path.join(ck_bib_dir, filename)

    # The BibTeX might be in bad shape (that's why the user is using ck_open_cmd to edit) so ck_info_cmd, might throw
    if extension.lower() != '.bib':
        ctx.invoke(ck_info_cmd, citation_key=citation_key)

    if extension.lower() == '.pdf':
        if os.path.exists(fullpath) is False:
            click.secho("ERROR: " + citation_key + " paper is NOT in the library as a PDF", fg="red", err=True)
            sys.exit(1)

        # not interested in output
        completed = subprocess.run(
            [ck_open, fullpath],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # TODO: check for failure in completed.returncode
    elif extension.lower() == '.bib':
        os.system(ck_text_editor + " " + fullpath)

        if os.path.exists(fullpath):
            print(file_to_string(fullpath).strip())
        
            try:
                # TODO: inefficient, reading bib file multiple times
                bib_rename_ck(fullpath, citation_key)

                bibtex = bib_read(fullpath)

                # warn if bib file is missing 'ckdateadded' field
                if 'ckdateadded' not in bibtex.entries[0]:
                    if click.confirm("\nWARNING: BibTeX is missing 'ckdateadded'. Would you like to set it to the current time?"):
                        # TODO: inefficient, reading bibfile twice
                        bib_set_dateadded(fullpath, None)
            except:
                click.secho('WARNING: Could not parse BibTeX:', fg='red')
                traceback.print_exc()

    elif extension.lower() == '.md':
        # NOTE: Need to cd to the directory first so vim picks up the .vimrc there
        os.system('cd "' + ck_bib_dir + '" && ' + ck_markdown_editor + ' "' + filename + '"')
    elif extension.lower() == '.html':
        if os.path.exists(fullpath) is False:
            click.secho("ERROR: No HTML notes in the library for '" + citation_key + "'", fg="red", err=True)
            sys.exit(1)

        completed = subprocess.run(
            [ck_open, fullpath],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    else:
        click.secho("ERROR: " + extension.lower() + " extension is not supported", fg="red", err=True)
        sys.exit(1)

@ck.command('bib')
@click.argument('citation_key', required=True, type=click.STRING)
@click.option(
    '--clipboard/--no-clipboard',
    default=True,
    help='To (not) copy the BibTeX to clipboard.'
    )
@click.option(
    '-m', '--markdown',
    is_flag=True,
    default=False,
    help='Output as a Markdown citation'
    )
@click.pass_context
def ck_bib_cmd(ctx, citation_key, clipboard, markdown):
    """Prints the paper's BibTeX and copies it to the clipboard."""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']

    # TODO: maybe add args for isolating author/title/year/etc

    path = ck_to_bib(ck_bib_dir, citation_key)
    if os.path.exists(path) is False:
        if click.confirm(citation_key + " has no .bib file. Would you like to create it?"):
            ctx.invoke(ck_open_cmd, filename=citation_key + ".bib")
        else:
            click.echo("Okay, will NOT create .bib file. Exiting...")
            sys.exit(1)

    if markdown == False:
        print("BibTeX for '%s'" % path)
        print()
        bibtex = file_to_string(path).strip().strip('\n').strip('\r').strip('\t')
        to_copy = bibtex
    else:
        try:
            with open(path) as bibf:
                parser = bibtexparser.bparser.BibTexParser(interpolate_strings=True, common_strings=True)
                bibtex = bibtexparser.load(bibf, parser)

            assert len(bibtex.entries) == 1
        except FileNotFoundError:
            print(citation_key + ":", "Missing BibTeX file in directory", ck_bib_dir)
        except:
            print(citation_key + ":", "Unexpected error")

        # TODO: check if it has a URL
        bib = bibtex.entries[0]
        title = bib['title'].strip("{}")
        authors = bib['author']
        year = bib['year']
        authors = authors.replace("{", "")
        authors = authors.replace("}", "")
        citation_key_noplus = citation_key.replace("+", "plus") # beautiful-jekyll is not that beautiful and doesn't like '+' in footnote names
        to_copy = "[^" + citation_key_noplus + "]: **" + title + "**, by " + authors

        if 'booktitle' in bib:
            venue = bib['booktitle']
        elif 'journal' in bib:
            venue = bib['journal']
        elif 'howpublished' in bib:
            venue = bib['howpublished']
        else:
            venue = None

        if venue != None:
            to_copy = to_copy + ", *in " + venue + "*"

        to_copy = to_copy +  ", " + year

        url = bib_get_url(bib)
        if url is not None:
            mdurl = "[[URL]](" + url + ")"
            to_copy = to_copy + ", " + mdurl

    print(to_copy)

    if clipboard:
        pyperclip.copy(to_copy)
        click.echo("\nCopied to clipboard!\n")

@ck.command('rename')
@click.argument('old_citation_key', required=True, type=click.STRING)
@click.argument('new_citation_key', required=True, type=click.STRING)
@click.pass_context
def ck_rename_cmd(ctx, old_citation_key, new_citation_key):
    """Renames a paper's .pdf and .bib file with a new citation key. Updates its .bib file and all symlinks to it in the TagDir."""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']
    ck_tags    = ctx.obj['tags']

    # make sure old CK exists and new CK does not
    if not ck_exists(ck_bib_dir, old_citation_key):
        click.secho("ERROR: Old citation key '" + old_citation_key + "' does NOT exist", fg="red")
        sys.exit(1)

    if ck_exists(ck_bib_dir, new_citation_key):
        click.secho("ERROR: New citation key '" + new_citation_key + "' already exists", fg="red")
        sys.exit(1)

    # find all files associated with the CK
    files = glob.glob(os.path.join(ck_bib_dir, old_citation_key) + '*')
    for f in files:
        path_noext, ext = os.path.splitext(f)
        # e.g.,
        # ('/Users/alinush/Dropbox/Papers/MBK+19', '.pdf')
        # ('/Users/alinush/Dropbox/Papers/MBK+19', '.bib')
        # ('/Users/alinush/Dropbox/Papers/MBK+19.slides', '.pdf')

        #dirname = os.path.dirname(path_noext)  # i.e., BibDir
        oldfilename = os.path.basename(path_noext)

        # replaces only the 1st occurrence of the old CK to deal with the (astronomically-rare?)
        # event where the old CK appears multiple times in the filename
        newfilename = oldfilename.replace(old_citation_key, new_citation_key, 1)
        if verbosity > 0:
            click.echo("Renaming '" + oldfilename + ext + "' to '" + newfilename + ext + "' in " + ck_bib_dir)

        # rename file in BibDir
        os.rename(
            os.path.join(ck_bib_dir, oldfilename + ext), 
            os.path.join(ck_bib_dir, newfilename + ext))

    # update .bib file citation key
    if verbosity > 0:
        click.echo("Renaming CK in .bib file...")
    bib_rename_ck(ck_to_bib(ck_bib_dir, new_citation_key), new_citation_key)

    # update all symlinks in TagDir by un-tagging and re-tagging
    if verbosity > 0:
        click.echo("Recreating tag information...")
    tags = ck_tags[old_citation_key]
    for tag in tags:
        if not untag_paper(ck_tag_dir, old_citation_key, tag):
            click.secho("WARNING: Could not remove '" + tag + "' tag", fg="red")

        if not tag_paper(ck_tag_dir, ck_bib_dir, new_citation_key, tag):
            click.secho("WARNING: Already has '" + tag + "' tag", fg="red")

@ck.command('search')
@click.argument('query', required=True, type=click.STRING)
@click.option(
    '-c', '--case-sensitive',
    is_flag=True,
    default=False,
    help='Enables case-sensitive search.'
    )
@click.pass_context
def ck_search_cmd(ctx, query, case_sensitive):
    """Searches all .bib files for the specified text."""

    ctx.ensure_object(dict)
    verbosity   = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tags    = ctx.obj['tags']

    cks = set()
    for relpath in os.listdir(ck_bib_dir):
        filepath = os.path.join(ck_bib_dir, relpath)
        filename, extension = os.path.splitext(relpath)
        #filename = os.path.basename(filepath)

        if extension.lower() == ".bib":
            origBibtex = file_to_string(filepath)

            if case_sensitive is False:
                bibtex = origBibtex.lower()
                query = query.lower()

                if query in bibtex:
                    cks.add(filename)

    if len(cks) > 0:
        include_url = True
        print_ck_tuples(cks_to_tuples(ck_bib_dir, cks, verbosity), ck_tags, include_url)
    else:
        print("No matches!")

@ck.command('cleanbib')
@click.pass_context
def ck_cleanbib_cmd(ctx):
    """Command to clean up the .bib files a little. (Temporary, until I write something better.)"""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = os.path.normpath(os.path.realpath(ctx.obj['TagDir']))

    cks = list_cks(ck_bib_dir)

    for ck in cks:
        bibfile = ck_to_bib(ck_bib_dir, ck)
        if verbosity > 1:
            print("Parsing BibTeX for " + ck)
        try:
            with open(bibfile) as bibf:
                parser = bibtexparser.bparser.BibTexParser(interpolate_strings=True, common_strings=True)
                bibtex = bibtexparser.load(bibf, parser)

            assert len(bibtex.entries) == 1
            assert type(ck) == str
            updated = canonicalize_bibtex(ck, bibtex, verbosity)

            if updated:
                print("Updating " + bibfile)
                bibwriter = BibTexWriter()
                with open(bibfile, 'w') as bibf:
                    bibf.write(bibwriter.write(bibtex))
            else:
                if verbosity > 0:
                    print("Nothing to update in " + bibfile)

        except FileNotFoundError:
            print(ck + ":", "Missing BibTeX file in directory", ck_bib_dir)
        except:
            print(ck + ":", "Unexpected error") 
            traceback.print_exc()

@ck.command('list')
#@click.argument('directory', required=False, type=click.Path(exists=True, file_okay=False, dir_okay=True, resolve_path=True))
#@click.argument('pathnames', nargs=-1, type=click.Path(exists=True, file_okay=True, dir_okay=True, resolve_path=True))
@click.argument('pathnames', nargs=-1, type=click.STRING)
@click.option(
    '-u', '--url',
    is_flag=True,
    default=False,
    help='Includes the URLs next to each paper'
    )
@click.option(
    '-s', '--short',
    is_flag=True,
    default=False,
    help='Citation keys only'
)
@click.option(
    '-r', '--relative',
    is_flag=True,
    default=False,
    help='Relative path to BibDir'
)
@click.pass_context
def ck_list_cmd(ctx, pathnames, url, short, relative):
    """Lists all citation keys in the library"""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = os.path.normpath(os.path.realpath(ctx.obj['TagDir']))
    ck_tags    = ctx.obj['tags']

    cks = cks_from_paths(ck_bib_dir, ck_tag_dir, pathnames, relative)
    
    if short:
        print(' '.join(cks))

    else:
        if verbosity > 0:
            print(cks)

        ck_tuples = cks_to_tuples(ck_bib_dir, cks, verbosity)

        sorted_cks = sorted(ck_tuples, key=lambda item: item[4])
    
        print_ck_tuples(sorted_cks, ck_tags, url)

        print()
        print(str(len(cks)) + " PDFs listed")

    # TODO: query could be a space-separated list of tokens
    # a token can be a hashtag (e.g., #dkg-dlog) or a sorting token (e.g., 'year')
    # For example: 
    #  $ ck l #dkg-dlog year title
    # would list all papers with tag #dkg-dlog and sort them by year and then by title
    # TODO: could have AND / OR operators for hashtags
    # TODO: filter by year/author/title/conference

@ck.command('genbib')
@click.argument('output-bibtex-file', required=True, type=click.File('w'))
@click.argument('pathnames', nargs=-1, type=click.Path(exists=True, file_okay=True, dir_okay=True, resolve_path=True))
@click.option(
    '-r', '--relative',
    is_flag=True,
    default=False,
    help='Relative path to BibDir'
)
@click.pass_context
def ck_genbib(ctx, output_bibtex_file, pathnames, relative):
    """Generates a master bibliography file of all papers."""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    cks = cks_from_paths(ck_bib_dir, ck_tag_dir, pathnames, relative)

    num = 0
    sortedcks = sorted(cks)
    for ck in sortedcks:
        bibfilepath = ck_to_bib(ck_bib_dir, ck)

        if os.path.exists(bibfilepath):
            num += 1
            bibtex = file_to_string(bibfilepath)
            output_bibtex_file.write(bibtex + '\n')

    if num == 0:
        print("No .bib files in specified directories.")
    else:
        print("Wrote", num, ".bib files to", output_bibtex_file.name)

@ck.command('copypdfs')
@click.argument('output-dir', required=True, type=click.Path(exists=True, file_okay=False, dir_okay=True, resolve_path=True))
@click.argument('pathnames', nargs=-1, type=click.Path(exists=True, file_okay=True, dir_okay=True, resolve_path=True))
@click.option(
    '-r', '--relative',
    is_flag=True,
    default=False,
    help='Relative path to BibDir'
)
@click.pass_context
def ck_copypdfs(ctx, output_dir, pathnames, relative):
    """Copies all PDFs from the specified directories into the output directory."""

    ctx.ensure_object(dict)
    verbosity  = ctx.obj['verbosity']
    ck_bib_dir = ctx.obj['BibDir']
    ck_tag_dir = ctx.obj['TagDir']

    cks = cks_from_paths(ck_bib_dir, ck_tag_dir, pathnames, relative)

    num = 0
    sortedcks = sorted(cks)
    for ck in sortedcks:

        if ck_exists(ck_bib_dir, ck):
            num += 1
            shutil.copy2(ck_to_pdf(ck_bib_dir, ck), output_dir)

    if num == 0:
        print("No .pdf files in specified directories.")
    else:
        print("Copied", num, ".pdf files to", output_dir)

if __name__ == '__main__':
    ck(obj={})

