#' Scale inferential replicate counts
#'
#' A helper function to scale the inferential replicates
#' to the mean sequencing depth. The scaling takes into account
#' a robust estimator of size factor (median ratio method is used).
#' First, counts are corrected per row using the effective lengths
#' (for gene counts, the average transcript lengths), then scaled
#' per column to the geometric mean sequence depth, and finally are
#' adjusted per-column up or down by the median ratio size factor to
#' minimize systematic differences across samples.
#'
#' @param y a SummarizedExperiment with: \code{infReps} a list of
#' inferential replicate count matrices, \code{counts} the
#' estimated counts matrix, and \code{length} the effective
#' lengths matrix
#' @param lengthCorrect whether to use effective length correction
#' (default is TRUE)
#' @param meanDepth (optional) user can
#' specify a different mean sequencing depth. By default
#' the geometric mean sequencing depth is computed
#' @param sfFun (optional) size factors function. An
#' alternative to the median ratio can be provided here to adjust
#' the scaledTPM so as to remove remaining library size differences.
#' Alternatively, one can provide a numeric vector of size factors
#' @param minCount for internal filtering, the minimum count 
#' @param minN for internal filtering, the minimum sample size
#' at \code{minCount}
#' @param quiet display no messages
#'
#' @return a SummarizedExperiment with the inferential replicates
#' as scaledTPM with library size already corrected (no need for further
#' normalization). A column \code{log10mean} is also added which is the
#' log10 of the mean of scaled counts across all samples and all inferential
#' replicates.
#'
#' @examples
#'
#' y <- makeSimSwishData()
#' y <- scaleInfReps(y)
#'
#' @import Rcpp
#' @export
scaleInfReps <- function(y, lengthCorrect=TRUE,
                         meanDepth=NULL, sfFun=NULL,
                         minCount=10, minN=3, quiet=FALSE) {
  if (!interactive()) {
    quiet <- TRUE
  }
  if (!is.null(metadata(y)$infRepsScaled)) {
    if (metadata(y)$infRepsScaled) stop("inferential replicates already scaled")
  }
  infRepIdx <- grep("infRep",assayNames(y))
  infRepError(infRepIdx)
  infReps <- assays(y)[infRepIdx]
  counts <- assays(y)[["counts"]]
  length <- assays(y)[["length"]]
  nreps <- length(infReps)
  if (is.null(meanDepth) & !is(sfFun,"numeric")) {
    meanDepth <- exp(mean(log(colSums(counts))))
  }
  means <- matrix(nrow=nrow(y), ncol=nreps)
  if (is.null(length)) {
    if (lengthCorrect) {
      if (!quiet) message("not correcting for feature length (lengthCorrect=FALSE)")
    }
    lengthCorrect <- FALSE
  }
  for (k in seq_len(nreps)) {
    if (!quiet) svMisc::progress(k, max.value=nreps, init=(k==1), gui=FALSE)
    if (lengthCorrect) {
      # new length bias correction matrix centered on 1
      length <- length / exp(rowMeans(log(length)))
      # a temporary matrix 'cts' which will store
      # the inferential replicate counts
      cts <- infReps[[k]] / length
    } else {
      # for 3' tagged scRNA-seq for example, don't length correct
      cts <- infReps[[k]]
    }
    # if size factors (numeric) were _not_ provided...
    if (!is(sfFun, "numeric")) {
      # divide out the column sum, then set all to the meanDepth
      cts <- t(t(cts) / colSums(cts)) * meanDepth
      # filtering for calculting median ratio size factors
      use <- rowSums(infReps[[k]] >= minCount) >= minN
      # calculate size factors
      if (is.null(sfFun)) {
        loggeomeans <- rowMeans(log(cts[use,]))
        sf <- apply(cts[use,], 2, function(s) {
          exp(median((log(s) - loggeomeans)[is.finite(loggeomeans)]))
        })
      } else if (is(sfFun, "function")) {
        sf <- sfFun(cts)
      }
      # ...otherwise we just divide counts by provided size factors
    } else {
      sf <- sfFun
    }
    infReps[[k]] <- t( t(cts)/sf )
    means[,k] <- rowMeans(infReps[[k]])
  }
  if (!quiet) message("")
  assays(y)[grep("infRep",assayNames(y))] <- infReps
  mcols(y)$log10mean <- log10(rowMeans(means) + 1)
  metadata(y)$infRepsScaled <- TRUE
  y
}

#' Label rows to keep based on minimal count
#'
#' Adds a column \code{keep} to \code{mcols(y)} that specifies
#' which rows of the SummarizedExperiment will be included
#' in statistical testing. Rows are not removed, just marked
#' with the logical \code{keep}.
#'
#' @param y a SummarizedExperiment
#' @param minCount the minimum count
#' @param minN the minimum sample size at \code{minCount}
#' @param x the name of the condition variable, will
#' use the smaller of the two groups to set \code{minN}.
#' Similar to edgeR's \code{filterByExpr}, as the smaller group
#' grows past 10, \code{minN} grows only by 0.7 increments
#' of sample size
#'
#' @return a SummarizedExperiment with a new column \code{keep}
#' in \code{mcols(y)}
#'
#' @examples
#' 
#' y <- makeSimSwishData()
#' y <- scaleInfReps(y)
#' y <- labelKeep(y)
#' 
#' @export
labelKeep <- function(y, minCount=10, minN=3, x) {
  if (!missing(x)) {
    stopifnot(x %in% names(colData(y)))
    minN <- min(table(colData(y)[[x]]))
    # this modeled after edgeR::filterByExpr()
    if (minN > 10) {
      minN <- 10 + (minN - 10) * 0.7
    }
  }
  cts <- assays(y)[["counts"]]
  if (is(cts, "dgCMatrix")) {
    keep <- Matrix::rowSums(cts >= minCount) >= minN
  } else {
    keep <- rowSums(cts >= minCount) >= minN
  }
  mcols(y)$keep <- keep
  metadata(y)$preprocessed <- TRUE
  y
}

#' Create isoform proportions from scaled data
#'
#' Takes output of scaled (and optionally filtered) counts
#' and returns isoform proportions by dividing out the
#' total scaled count for the gene for each sample.
#' The operation is performed on the \code{counts} assay,
#' then creating a new assay called \code{isoProp},
#' and on all of the inferential replicates, turning them
#' from counts into isoform proportions. Any transcripts
#' (rows) from single isoform genes are removed, and the
#' transcripts will be re-ordered by gene ID.
#'
#' @param y a SummarizedExperiment
#' @param geneCol the name of the gene ID column in the
#' metadata columns for the rows of \code{y}
#' @param quiet display no messages
#'
#' @return a SummarizedExperiment, with single-isoform
#' transcripts removed, and transcripts now ordered by
#' gene
#' 
#' @export
isoformProportions <- function(y, geneCol="gene_id", quiet=FALSE) {
  if (!interactive()) {
    quiet <- TRUE
  }
  if (is.null(metadata(y)$infRepsScaled)) {
    stop("first run scaleInfReps()")
  }
  if (!is.null(metadata(y)$infRepsProportions)) {
    if (metadata(y)$infRepsProportions) stop("inferential replicates already proportions")
  }
  stopifnot(geneCol %in% names(mcols(y)))

  gene <- mcols(y)[[geneCol]]
  stopifnot(all(lengths(gene) == 1))
  mcols(y)$gene <- unlist(gene)
  gene.tbl <- table(mcols(y)$gene)
  # remove single isoform genes
  keep <- mcols(y)$gene %in% names(gene.tbl)[gene.tbl > 1]
  stopifnot(sum(keep) > 0)
  y <- y[keep,]
  y <- y[order(mcols(y)$gene),]
  assays(y, withDimnames=FALSE)[["isoProp"]] <- makeIsoProp(
    assays(y)[["counts"]],
    mcols(y)$gene
  )
  
  infRepIdx <- grep("infRep",assayNames(y))
  infRepError(infRepIdx)
  infReps <- assays(y)[infRepIdx]
  nreps <- length(infReps)
  for (k in seq_len(nreps)) {
    if (!quiet) svMisc::progress(k, max.value=nreps, init=(k==1), gui=FALSE)
    infReps[[k]] <- makeIsoProp(infReps[[k]],
                                mcols(y)$gene)
  }
  if (!quiet) message("")
  
  assays(y)[grep("infRep",assayNames(y))] <- infReps
  metadata(y)$infRepsProportions <- TRUE
  y
}

# not exported
makeIsoProp <- function(counts, gene) {
  totals <- rowsum(counts, gene)
  # if a sample has a gene total of 0, replace here with 1 to avoid division by 0
  totals[totals == 0] <- 1
  ngene <- length(unique(gene))
  gene.tbl <- table(gene)
  idx <- rep(seq_len(ngene), gene.tbl)
  big.totals <- totals[idx,]
  counts / big.totals
}

#' Make pseudo-inferential replicates from mean and variance
#'
#' Makes pseudo-inferential replicate counts from
#' \code{mean} and \code{variance} assays. The simulated
#' counts are drawn from a negative binomial distribution,
#' with \code{mu=mean} and \code{size} set using a method
#' of moments estimator for dispersion.
#'
#' Note that these simulated counts only reflect marginal
#' variance (one transcript or gene at a time),
#' and do not capture the covariance of counts across
#' transcripts or genes, unlike imported inferential
#' replicate data. Therefore, \code{makeInfReps} should
#' not be used with \code{summarizeToGene} to create
#' gene-level inferential replicates if inferential
#' replicates were originally created on the transcript
#' level. Instead, import the original inferential
#' replicates.
#'
#' @param y a SummarizedExperiment
#' @param numReps how many inferential replicates
#' @param minDisp the minimal dispersion value,
#' set after method of moments estimation from
#' inferential mean and variance
#'
#' @return a SummarizedExperiment
#'
#' @references
#'
#' Van Buren, S., Sarkar, H., Srivastava, A., Rashid, N.U.,
#' Patro, R., Love, M.I. (2020)
#' Compression of quantification uncertainty for scRNA-seq counts.
#' bioRxiv.
#' \url{https://doi.org/10.1101/2020.07.06.189639}
#' 
#' @examples
#'
#' library(SummarizedExperiment)
#' mean <- matrix(1:4,ncol=2)
#' variance <- mean
#' se <- SummarizedExperiment(list(mean=mean, variance=variance))
#' se <- makeInfReps(se, numReps=50)
#' 
#' @export
makeInfReps <- function(y, numReps, minDisp=1e-3) {
  stopifnot(is(y, "SummarizedExperiment"))
  stopifnot("mean" %in% assayNames(y))
  stopifnot("variance" %in% assayNames(y))
  stopifnot(numReps > 1)
  stopifnot(round(numReps) == numReps)
  if (any(grepl("infRep", assayNames(y)))) {
    stop("infReps already exist, remove these first")
  }
  # drop sparsity here
  m <- as.matrix(assays(y)[["mean"]])
  v <- as.matrix(assays(y)[["variance"]])
  disp <- ifelse(m > 0, pmax(minDisp, (v - m)/m^2), minDisp)
  infReps <- list()
  for (k in seq_len(numReps)) {
    infReps[[k]] <- matrix(rnbinom(n=nrow(y)*ncol(y), mu=m, size=1/disp),
                           ncol=ncol(y), dimnames=dimnames(m))
  }
  names(infReps) <- paste0("infRep", 1:numReps)
  assays(y) <- c(assays(y), infReps)
  metadata(y)$infRepsScaled <- FALSE
  y
}

#' Function for splitting SummarizedExperiment into separate RDS files
#'
#' The \code{splitSwish} function splits up the \code{y} object
#' along genes and writes a \code{Snakefile} that can be used with
#' Snakemake to distribute running \code{swish} across genes.
#' This workflow is primarily designed for large single cell datasets,
#' and so the default is to not perform length correction
#' within the distributed jobs.
#' See the alevin section of the vignette for an example. See
#' the Snakemake documention for details on how to run and customize
#' a \code{Snakefile}: \url{https://snakemake.readthedocs.io}
#' 
#' @param y a SummarizedExperiment
#' @param nsplits integer, how many pieces to break \code{y} into
#' @param prefix character, the path of the RDS files to write out,
#' e.g. \code{prefix="/path/to/swish"} will generate \code{swish.rds}
#' files at this path
#' @param snakefile character, the path of a Snakemake file, e.g.
#' \code{Snakefile}, that should be written out. If \code{NULL},
#' then no \code{Snakefile} is written out
#' @param overwrite logical, whether the \code{snakefile} and
#' RDS files (\code{swish1.rds}, ...) should overwrite existing files
#'
#' @references
#'
#' Compression and splitting across jobs:
#' 
#' Van Buren, S., Sarkar, H., Srivastava, A., Rashid, N.U.,
#' Patro, R., Love, M.I. (2020)
#' Compression of quantification uncertainty for scRNA-seq counts.
#' bioRxiv.
#' \url{https://doi.org/10.1101/2020.07.06.189639}
#'
#' Snakemake:
#' 
#' Koster, J., Rahmann, S. (2012)
#' Snakemake - a scalable bioinformatics workflow engine.
#' Bioinformatics.
#' \url{https://doi.org/10.1093/bioinformatics/bts480}
#' 
#' @return nothing, files are written out
#'
#' @export
splitSwish <- function(y, nsplits, prefix="swish",
                       snakefile=NULL, overwrite=FALSE) {
  stopifnot(nsplits > 1)
  stopifnot(nsplits == round(nsplits))
  stopifnot(nsplits < nrow(y))
  stopifnot(!is.null(rownames(y)))
  stopifnot(all(mcols(y)$keep))
  stopifnot(basename(prefix) == "swish")
  if (!is.null(snakefile)) {
    stopifnot(is(snakefile, "character"))
    if (file.exists(snakefile) & !overwrite)
      stop("snakefile already exists at specified location, see 'overwrite'")
    snake <- scan(system.file("extdata/Snakefile", package="fishpond"),
                  what="character", sep="\n", blank.lines.skip=FALSE,
                  quiet=TRUE)
    write(snake, file=snakefile)
  }
  # how many leading 0's
  width <- floor(log10(nsplits)) + 1
  nums <- formatC(seq_len(nsplits), width=max(2, width),
                  format="d", flag="0")
  files <- paste0(prefix, nums, ".rds")
  if (any(file.exists(files)) & !overwrite)
    stop("Swish RDS files exist at specified locations, see 'overwrite'")
  idx <- sort(rep(seq_len(nsplits), length.out=nrow(y)))
  for (i in seq_len(nsplits)) {
    saveRDS(y[idx == i,], file=files[i])
  }
}

#' Helper function for distributing Swish on a subset of data
#'
#' This function is called by the \code{Snakefile} that is generated
#' by \code{\link{splitSwish}}. See alevin example in the vignette.
#' As such, it doesn't need to be run by users in an interactive
#' R session.
#' 
#' Note that the default for length correction is FALSE, as
#' opposed to the default in \code{\link{scaleInfReps}} which
#' is TRUE. The default for \code{numReps} here is 20.
#' 
#' @param infile path to an RDS file of a SummarizedExperiment
#' @param outfile a CSV file to write out
#' @param numReps how many inferential replicates to generate
#' @param lengthCorrect logical, see \code{\link{scaleInfReps}},
#' and Swish vignette. As this function is primarily for alevin,
#' the default is \code{FALSE}
#' @param overwrite logical, whether \code{outfile}
#' should overwrite an existing file
#' @param ... arguments passed to \code{\link{swish}}
#'
#' @return nothing, files are written out
#'
#' @export
miniSwish <- function(infile, outfile, numReps=20,
                      lengthCorrect=FALSE, overwrite=FALSE, ...) {
  stopifnot(all(is(c(infile, outfile), "character")))
  stopifnot(file.exists(infile))
  if (file.exists(outfile) & !overwrite)
    stop("outfile already exists at specified location, see 'overwrite'")
  y <- readRDS(infile)
  stopifnot(!is.null(rownames(y)))
  stopifnot(all(mcols(y)$keep))
  y <- makeInfReps(y, numReps=numReps)
  if (is.null(colData(y)$sizeFactor))
    stop("miniSwish requires pre-estimated sizeFactors stored in colData(...)")
  y <- scaleInfReps(y, lengthCorrect=lengthCorrect, sfFun=colData(y)$sizeFactor)
  out <- swish(y=y, returnNulls=TRUE, ...)
  mat <- cbind(out$stat, out$log2FC, out$nulls)
  rownames(mat) <- rownames(y)
  write.table(mat, file=outfile, col.names=FALSE, sep=",")
}

#' Read statistics and nulls from CSV file
#'
#' After running \code{\link{splitSwish}} and the associated
#' \code{Snakefile}, this function can be used to gather and
#' add the results to the original object. See the alevin
#' section of the vignette for an example.
#'
#' @param y a SummarizedExperiment (if NULL, function will
#' output a data.frame)
#' @param infile character, path to the \code{summary.csv} file
#' @param estPi0 logical, see \code{\link{swish}}
#'
#' @return the SummarizedExperiment with metadata columns added,
#' or if \code{y} is NULL, a data.frame of compiled results
#'
#' @export
addStatsFromCSV <- function(y=NULL, infile, estPi0=FALSE) {
  res <- read.table(infile, header=FALSE, row.names=1, sep=",")
  stat <- res[,1]
  log2FC <- res[,2]
  nulls <- as.matrix(res[,-c(1:2)])
  pvalue <- qvalue::empPvals(abs(stat), abs(nulls))
  pi0 <- if (estPi0) NULL else 1
  q.res <- qvalue::qvalue(pvalue, pi0=pi0)
  locfdr <- q.res$lfdr
  qvalue <- q.res$qvalues
  df <- data.frame(stat, log2FC, pvalue, locfdr, qvalue, row.names=rownames(res))
  if (is.null(y)) {
    return(df)
  } else {
    stopifnot(all(rownames(y) == rownames(df)))
    return(postprocess(y, df))
  }
}

#' Make simulated data for swish for examples/testing
#'
#' Makes a small swish dataset for examples and testing.
#' The first six genes have some differential expression
#' evidence in the counts, with varying degree of inferential
#' variance across inferential replicates (1-2: minor,
#' 3-4: some, 5-6: substantial). The 7th and 8th
#' genes have all zeros to demonstrate \code{labelKeep}.
#' 
#' @param m number of genes
#' @param n number of samples
#' @param numReps how many inferential replicates to generate
#' @param null logical, whether to make an all null dataset
#' @param meanVariance logical, whether to output only mean and
#' variance of inferential replicates
#'
#' @return a SummarizedExperiment
#'
#' @examples
#'
#' library(SummarizedExperiment)
#' y <- makeSimSwishData()
#' assayNames(y)
#' 
#' @export
makeSimSwishData <- function(m=1000, n=10, numReps=20, null=FALSE, meanVariance=FALSE) {
  stopifnot(m>8)
  stopifnot(n %% 2 == 0)
  cts <- matrix(rpois(m*n, lambda=80), ncol=n)
  if (!null) {
    grp2 <- (n/2+1):n
    cts[1:6,grp2] <- rpois(3*n, lambda=120)
    cts[7:8,] <- 0
  }
  length <- matrix(1000, nrow=m, ncol=n)
  abundance <- t(t(cts)/colSums(cts))*1e6
  infReps <- lapply(seq_len(numReps), function(i) {
    m <- matrix(rpois(m*n, lambda=80), ncol=n)
    if (!null) {
      # these row numbers are fixed for the demo dataset
      m[1:6,grp2] <- rpois(3*n, lambda=120)
      m[3:4,] <- round(m[3:4,] * runif(2*n,.5,1.5))
      m[5:6,grp2] <- round(pmax(m[5:6,grp2] + runif(n,-120,80),0))
      m[7:8,] <- 0
    }
    m
  })
  names(infReps) <- paste0("infRep", seq_len(numReps))
  if (meanVariance) {
    infRepsCube <- abind::abind(infReps, along=3)
    mu <- apply(infRepsCube, 1:2, mean)
    variance <- apply(infRepsCube, 1:2, var)
    assays <- list(counts=cts, abundance=abundance, length=length,
                   mean=mu, variance=variance)
  } else {
    assays <- list(counts=cts, abundance=abundance, length=length)
    assays <- c(assays, infReps)
  }
  se <- SummarizedExperiment(assays=assays)
  rownames(se) <- paste0("gene-",seq_len(nrow(se)))
  metadata(se) <- list(countsFromAbundance="no")
  colData(se) <- DataFrame(condition=gl(2,n/2))
  se
}

#' Compute inferential relative variance (InfRV)
#'
#' \code{InfRV} is used the Swish publication for visualization.
#' This function provides computation of the mean InfRV, a simple
#' statistic that measures inferential uncertainty.
#' Note that InfRV is not used in the \code{swish}
#' statistical method at all, it is just for visualization.
#' See function code for details.
#'
#' @param y a SummarizedExperiment
#' @param pc a pseudocount parameter for the denominator
#' @param shift a final shift parameter
#' @param meanVariance logical, use pre-computed inferential mean
#' and variance assays instead of \code{counts} and
#' computed variance from \code{infReps}. If missing,
#' will use pre-computed mean and variance when present.
#'
#' @return a SummarizedExperiment with \code{meanInfRV} in the metadata columns
#'
#' @export
computeInfRV <- function(y, pc=5, shift=.01, meanVariance) {
  if (missing(meanVariance)) {
    meanVariance <- all(c("mean","variance") %in% assayNames(y))
  }
  if (meanVariance) {
    stopifnot(all(c("mean","variance") %in% assayNames(y)))
    infVar <- assays(y)[["variance"]]
    mu <- assays(y)[["mean"]]
  } else {
    infReps <- assays(y)[grep("infRep",assayNames(y))]
    infReps <- abind::abind(as.list(infReps), along=3)
    infVar <- apply(infReps, 1:2, var)
    mu <- assays(y)[["counts"]]
  }
  # the InfRV computation:
  InfRV <- pmax(infVar - mu, 0)/(mu + pc) + shift
  mcols(y)$meanInfRV <- rowMeans(InfRV)
  y
}

postprocess <- function(y, df) {
  for (stat in names(df)) {
    mcols(y)[[stat]] <- numeric(nrow(y))
    mcols(y)[[stat]][mcols(y)$keep] <- df[[stat]]
    mcols(y)[[stat]][!mcols(y)$keep] <- NA
  }
  y
}

infRepError <- function(infRepIdx) {
  if (length(infRepIdx) == 0) {
    stop("there are no inferential replicates in the assays of 'y'")
  }
}
