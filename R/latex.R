#' Compile a LaTeX document to PDF
#'
#' The function \code{latexmk()} uses the system command \command{latexmk} to
#' compile a LaTeX document to PDF; if \command{latexmk} is not available, use a
#' simple emulation. The functions \code{pdflatex()}, \code{xelatex()}, and
#' \code{lualatex()} are wrappers of \code{latexmk(engine =, emulation = TRUE)}.
#'
#' The \command{latexmk} emulation works like this: run the LaTeX engine once
#' (e.g., \command{pdflatex}), run \command{makeindex} to make the index if
#' necessary (the \file{*.idx} file exists), run the bibliography engine
#' \command{bibtex} or \command{biber} to make the bibliography if necessary
#' (the \file{*.aux} or \file{*.bcf} file exists), and finally run the LaTeX
#' engine a number of times (the maximum is 10 by default) to resolve all
#' cross-references.
#' @param file A LaTeX file path.
#' @param engine A LaTeX engine.
#' @param bib_engine A bibliography engine.
#' @param emulation Whether to use \command{latexmk} emulation (by default,
#'   \code{TRUE} if the command \command{latexmk} is not available). You can set
#'   the global option \code{options(tinytex.latexmk.emulation = TRUE)} to
#'   always use emulation.
#' @param max_times The maximum number of times to rerun the LaTeX engine when
#'   using emulation. You can set the global option
#'   \code{tinytex.compile.max_times}, e.g.,
#'   \code{options(tinytex.compile.max_times = 3)}.
#' @param install_packages Whether to automatically install missing LaTeX
#'   packages found by \code{\link{parse_packages}()} from the LaTeX log. This
#'   argument is only for the emulation mode and TeX Live.
#' @export
latexmk = function(
  file, engine = c('pdflatex', 'xelatex', 'lualatex'), bib_engine = c('bibtex', 'biber'),
  emulation = TRUE, max_times = 10, install_packages = emulation && tlmgr_available()
) {
  if (!grepl('[.]tex$', file))
    stop("The input file '", file, "' does not appear to be a LaTeX document")
  engine = gsub('^(pdf|xe|lua)(tex)$', '\\1la\\2', engine)  # normalize *tex to *latex
  engine = match.arg(engine)
  if (missing(emulation))
    emulation = getOption('tinytex.latexmk.emulation', Sys.which('latexmk') == '')
  if (missing(max_times)) max_times = getOption('tinytex.compile.max_times', 10)
  if (emulation || Sys.which('perl') == '' || system2_quiet('latexmk', '-v') != 0) {
    return(latexmk_emu(file, engine, bib_engine, max_times, install_packages))
  }
  system2_quiet('latexmk', c(
    '-pdf -latexoption=-halt-on-error -interaction=batchmode',
    paste0('-pdflatex=', engine), shQuote(file)
  ), error = {
    if (install_packages && !emulation) warning(
      'latexmk(install_packages = TRUE) does not work when emulation = FALSE'
    )
    check_latexmk_version()
    show_latex_error(file)
  })
  system2('latexmk', '-c', stdout = FALSE)  # clean up nonessential files
}

#' @param ... Arguments to be passed to \code{latexmk()} (other than
#'   \code{engine} and \code{emulation}).
#' @rdname latexmk
#' @export
pdflatex = function(...) latexmk(engine = 'pdflatex', emulation = TRUE, ...)

#' @rdname latexmk
#' @export
xelatex  = function(...) latexmk(engine = 'xelatex',  emulation = TRUE, ...)

#' @rdname latexmk
#' @export
lualatex = function(...) latexmk(engine = 'lualatex', emulation = TRUE, ...)

# a quick and dirty version of latexmk (should work reasonably well unless the
# LaTeX document is extremely complicated)
latexmk_emu = function(file, engine, bib_engine = c('bibtex', 'biber'), times, install_packages) {
  owd = setwd(dirname(file))
  on.exit(setwd(owd), add = TRUE)
  # only use basename because bibtex may not work with full path
  file = basename(file)
  aux = c(
    'log', 'aux', 'bbl', 'blg', 'fls', 'out', 'lof', 'lot', 'idx', 'toc',
    'nav', 'snm', 'vrb', 'ilg', 'ind', 'xwm', 'bcf', 'brf', 'run.xml'
  )
  base = gsub('[.]tex$', '', file)
  aux_files = paste(base, aux, sep = '.')
  logfile = aux_files[1]; unlink(logfile)  # clean up the log before compilation

  # clean up aux files from LaTeX compilation
  files1 = exist_files(aux_files)
  keep_log = FALSE
  on.exit(add = TRUE, {
    files2 = exist_files(aux_files)
    files3 = setdiff(files2, files1)
    if (keep_log) files3 = setdiff(files3, logfile)
    unlink(files3)
  })

  pkgs_last = character()
  filep = normalizePath(paste0(base, '.pdf'), mustWork = FALSE)
  # backup the PDF output if it exists, and move it back if the compilation failed
  if (file.exists(filep)) {
    filep2 = normalizePath(tempfile('tinytex_', '.', '.pdf'), mustWork = FALSE)
    if (file.rename(filep, filep2)) on.exit(
      if (file.exists(filep)) file.remove(filep2) else file.rename(filep2, filep),
      add = TRUE
    )
  }
  run_engine = function() {
    on_error  = function() {
      if (install_packages && file.exists(logfile)) {
        pkgs = parse_packages(logfile)
        if (length(pkgs) && !identical(pkgs, pkgs_last)) {
          message('Trying to automatically install missing LaTeX packages...')
          if (tlmgr_install(pkgs) == 0) {
            pkgs_last <<- pkgs
            run_engine()
          }
        }
      }
      keep_log <<- TRUE
      show_latex_error(file, logfile)
    }
    res = system2_quiet(
      engine, c('-halt-on-error -interaction=batchmode', shQuote(file)),
      error = on_error(), fail_rerun = FALSE
    )
    # PNAS you are the worst! Why don't you singal an error in case of missing packages?
    if (res == 0 && !file.exists(filep)) on_error()
    invisible(res)
  }
  run_engine()
  # generate index
  idx = sub('[.]tex$', '.idx', file)
  if (file.exists(idx)) {
    system2_quiet('makeindex', shQuote(idx), error = {
      stop("Failed to build the index via makeindex", call. = FALSE)
    })
  }
  # generate bibliography
  bib_engine = match.arg(bib_engine)
  if (install_packages && bib_engine == 'biber' && Sys.which('biber') == '')
    tlmgr_install('biber')
  aux_ext = if ((biber <- bib_engine == 'biber')) '.bcf' else '.aux'
  aux = sub('[.]tex$', aux_ext, file)
  if (file.exists(aux)) {
    if (biber || require_bibtex(aux)) {
      blg = aux_files[4]  # bibliography log file
      build_bib = function() system2_quiet(bib_engine, shQuote(aux), error = {
        stop("Failed to build the bibliography via ", bib_engine, call. = FALSE)
      })
      build_bib()
      check_blg = function() {
        if (!file.exists(blg)) return(TRUE)
        x = readLines(blg)
        if (length(grep('error message', x)) == 0) return(TRUE)
        warn = function() {
          warning(
            bib_engine, ' seems to have failed:\n\n', paste(x, collapse = '\n'),
            call. = FALSE
          )
          TRUE
        }
        if (!tlmgr_available() || !install_packages) return(warn())
        # install the possibly missing .bst package and rebuild bib
        r = '.* open style file ([^ ]+).*'
        pkgs = parse_packages(files = gsub(r, '\\1', grep(r, x, value = TRUE)))
        if (length(pkgs) == 0) return(warn())
        tlmgr_install(pkgs); build_bib()
        FALSE
      }
      # check .blg at most 3 times for missing packages
      for (i in 1:3) if (check_blg()) break
    }
  }
  for (i in seq_len(times)) {
    if (file.exists(logfile)) {
      if (!any(grepl('(Rerun to get|Please \\(re\\)run) ', readLines(logfile)))) break
    } else warning('The LaTeX log file "', logfile, '" is not found')
    run_engine()
  }
}

require_bibtex = function(aux) {
  x = readLines(aux)
  r = length(grep('^\\\\citation\\{', x)) && length(grep('^\\\\bibdata\\{', x)) &&
    length(grep('^\\\\bibstyle\\{', x))
  if (r && !tlmgr_available() && os == 'windows') tweak_aux(aux, x)
  r
}

# remove the .bib extension in \bibdata{} in the .aux file, because bibtex on
# Windows requires no .bib extension (sigh)
tweak_aux = function(aux, x = readLines(aux)) {
  r = '^\\\\bibdata\\{.+\\}\\s*$'
  if (length(i <- grep(r, x)) == 0) return()
  x[i] = gsub('[.]bib([,}])', '\\1', x[i])
  writeLines(x, aux)
}

system2_quiet = function(..., error = NULL, fail_rerun = TRUE) {
  # run the command quietly if possible
  res = system2(..., stdout = FALSE, stderr = FALSE)
  # if failed, use the normal mode
  if (fail_rerun && res != 0) res = system2(...)
  # if still fails, run the error callback
  if (res != 0) error  # lazy evaluation
  invisible(res)
}

# parse the LaTeX log and show error messages
show_latex_error = function(file, logfile = gsub('[.]tex$', '.log', file)) {
  e = c('Failed to compile ', file, '.')
  if (!file.exists(logfile)) stop(e, call. = FALSE)
  x = readLines(logfile, warn = FALSE)
  b = grep('^\\s*$', x)  # blank lines
  m = NULL
  for (i in grep('^! ', x)) {
    # ignore the last error message about the fatal error
    if (grepl('==> Fatal error occurred', x[i], fixed = TRUE)) next
    n = b[b > i]
    n = if (length(n) == 0) i else min(n) - 1L
    m = c(m, x[i:n], '')
  }
  if (length(m)) {
    message(paste(m, collapse = '\n'))
    stop(e, ' See ', logfile, ' for more info.', call. = FALSE)
  }
}

# check the version of latexmk
check_latexmk_version = function() {
  out = system2('latexmk', '-v', stdout = TRUE)
  reg = '^.*Version (\\d+[.]\\d+).*$'
  out = grep(reg, out, value = TRUE)
  if (length(out) == 0) return()
  ver = as.numeric_version(gsub(reg, '\\1', out[1]))
  if (ver >= '4.43') return()
  system2('latexmk', '-v')
  warning(
    'Your latexmk version seems to be too low. ',
    'You may need to update the latexmk package or your LaTeX distribution.',
    call. = FALSE
  )
}

# return file paths that exist
exist_files = function(files) {
  files[utils::file_test('-f', files)]
}

#' Find missing LaTeX packages from a LaTeX log file
#'
#' Analyze the error messages in a LaTeX log file to figure out the names of
#' missing LaTeX packages that caused the errors. These packages can be
#' installed via \code{\link{tlmgr_install}()}. Searching for missing packages
#' is based on \code{\link{tlmgr_search}()}.
#' @param log Path to the LaTeX log file (typically named \file{*.log}).
#' @param text A character vector of the error log (read from the file provided
#'   by the \code{log} argument by default).
#' @param files A character vector of names of the missing files (automatically
#'   detected from the \code{log} by default).
#' @param quiet Whether to suppress messages when finding packages.
#' @return A character vector of LaTeX package names.
#' @export
parse_packages = function(
  log, text = readLines(log), files = detect_files(text), quiet = FALSE
) {
  pkgs = character()
  x = files
  if (length(x) == 0) {
    if (!quiet) message(
      'I was unable to find any missing LaTeX packages from the error log',
      if (missing(log)) '.' else c(' ', log, '.')
    )
    return(invisible(pkgs))
  }
  for (j in seq_along(x)) {
    l = tlmgr_search(paste0('/', x[j]), stdout = TRUE, .quiet = quiet)
    if (length(l) == 0) next
    if (x[j] == 'fandol') return(x[j])  # a known package
    # why $? e.g. searching for mf returns a list like this
    # metafont.x86_64-darwin:
    #     bin/x86_64-darwin/mf       <- what we want
    # metapost.x86_64-darwin:
    #     bin/x86_64-darwin/mfplain  <- but this also matches /mf
    k = grep(paste0('/', x[j], '$'), l)  # only match /mf exactly
    if (length(k) == 0) {
      if (!quiet) warning('Failed to find a package that contains ', x[j])
      next
    }
    k = k[k > 2]
    p = grep(':$', l)
    if (length(p) == 0) next
    for (i in k) {
      pkg  = gsub(':$', '', l[max(p[p < i])])  # find the package name
      pkgs = c(pkgs, setNames(pkg, x[j]))
    }
  }
  pkgs = gsub('[.].*', '', pkgs)  # e.g., 'metafont.x86_64-darwin'
  unique(pkgs)
}

# find filenames (could also be font names) from LaTeX error logs
detect_files = function(text) {
  # possible errors are like:
  # ! LaTeX Error: File `framed.sty' not found.
  # /usr/local/bin/mktexpk: line 123: mf: command not found
  # ! Font U/psy/m/n/10=psyr at 10.0pt not loadable: Metric (TFM) file not found
  # !pdfTeX error: /usr/local/bin/pdflatex (file tcrm0700): Font tcrm0700 at 600 not found
  # ! The font "FandolSong-Regular" cannot be found.
  # ! Package babel Error: Unknown option `ngerman'. Either you misspelled it
  # (babel)                or the language definition file ngerman.ldf was not found.
  # !pdfTeX error: pdflatex (file 8r.enc): cannot open encoding file for reading
  # ! CTeX fontset `fandol' is unavailable in current mode
  # Package widetext error: Install the flushend package which is a part of sttools
  r = c(
    ".*! Font [^=]+=([^ ]+).+ not loadable.*",
    '.*! The font "([^"]+)" cannot be found.*',
    '.*!.+ error:.+\\(file ([^)]+)\\): .*',
    '.*Package widetext error: Install the ([^ ]+) package.*',
    ".*! LaTeX Error: File `([^']+)' not found.*",
    '.*the language definition file ([^ ]+) .*',
    '.* \\(file ([^)]+)\\): cannot open .*',
    ".*! CTeX fontset `([^']+)' is unavailable.*",
    ".*: ([^:]+): command not found.*"
  )
  x = grep(paste(r, collapse = '|'), text, value = TRUE)
  if (length(x) > 0) unique(unlist(lapply(r, function(p) {
    z = grep(p, x, value = TRUE)
    v = gsub(p, '\\1', z)
    if (length(v) == 0 || !(p %in% r[1:4])) return(v)
    if (p == r[4]) return(paste0(v, '.sty'))
    i = !grepl('[.]', v)
    v[i] = paste0(v[i], '[.](tfm|afm|mf|otf)')
    v
  })))
}

# it should be rare that we need to manually run texhash
texhash = function() system2('texhash')

fmtutil = function(usermode = FALSE) {
  system2(if (usermode) 'fmtutil-user' else 'fmtutil-sys', '--all')
}

# look up files in the Kpathsea library, e.g., kpsewhich('Sweave.sty')
kpsewhich = function(filename, options = character()) {
  system2('kpsewhich', c(options, shQuote(filename)))
}
