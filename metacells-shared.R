# metacell functions that are used both online and offline

suppressWarnings(dir.create(glue("{cache.dir}/metacells"), recursive = TRUE))

per.100k <- function(x) round(100000*x+1)
log.transform <- function(x) log(per.100k(x))

# User can specify >1 cx or cmp.cx. generate weighted means and sum sums.
merge.cxs <- function(cxs, kind) {

  # data is stored per exp.label. Read once for all clusters in that region.
  means.sums <-
    dlply(cxs, .(exp.label), function(cxs.exp) {
      fn.means <- glue("{prep.dir}/metacells/{first(cxs.exp$exp.label)}.{kind}.means.RDS")
      fn.sums <- glue("{prep.dir}/metacells/{first(cxs.exp$exp.label)}.{kind}.sums.RDS")
      
      means <- select(readRDS(fn.means), c('gene',cxs.exp$cx))
      
      sums <- select(readRDS(fn.sums), c('gene', cxs.exp$cx))
      
      list(means=means, sums=sums)
    })
  
  # combine into a single table with only common genes
  inner_join_by_gene <- function(x,y) inner_join(x,y,by='gene')
  means <- Reduce(inner_join_by_gene, lapply(means.sums, function(ms) ms$means))
  sums <- Reduce(inner_join_by_gene, lapply(means.sums, function(ms) ms$sums))
    
  # get relative sizes of clusters
  totals <- apply(sums[2:ncol(sums)], 2, sum)
  grand.total <- sum(totals)
    
  means.vals <- apply(means[2:ncol(means)], 1, function(row) sum(row*totals)/grand.total)
  sums.vals <- apply(sums[2:ncol(sums)], 1, sum)
    
  list(means=tibble(gene=means$gene, means=means.vals), sums=tibble(gene=sums$gene, sums=sums.vals))
}

compute.pair <- function(exp.label, cx, cmp.exp.label, cmp.cx, kind, use.cached=TRUE, pairs.dir=glue("{cache.dir}/metacells")) {
  
  targets <- tibble(exp.label=exp.label, cx=cx)
  comparisons <- tibble(exp.label=cmp.exp.label, cx=cmp.cx)

  target.names.tbl <- select(inner_join(experiments, targets, by='exp.label'), exp.abbrev, cx)
  target.names <- paste(glue("{target.names.tbl$exp.abbrev}.{target.names.tbl$cx}"),collapse='+')
  comparison.names.tbl <- select(inner_join(experiments, comparisons, by='exp.label'), exp.abbrev, cx)
  comparison.names <- paste(glue("{comparison.names.tbl$exp.abbrev}.{comparison.names.tbl$cx}"),collapse='+')
  
  cache.file <- glue("{pairs.dir}/{target.names}.vs.{comparison.names}.RDS")
  alt.cache.file <- glue("{prep.dir}/pairs/{target.names}.vs.{comparison.names}.RDS") # check for pre-computed
  
  if (use.cached && (file.exists(cache.file) || file.exists(alt.cache.file))) {
    if (file.exists(cache.file)) {
      x <- readRDS(cache.file)
    } else {
      x <- readRDS(alt.cache.file)
    }
  } else {
    progress <- shiny.progress(glue("{kind} pairwise - {target.names} vs {comparison.names}"))
    if (!is.null(progress)) on.exit(progress$close())
    
    write.log(glue("Computing pairwise {target.names} vs {comparison.names}"))
    
    if (!is.null(progress)) {
      progress$inc(0.3, detail=glue("Reading means and sums from disk"))
    }

    means.sums.tgt <- merge.cxs(targets, kind)
    means.tgt <- means.sums.tgt$means
    sums.tgt <- means.sums.tgt$sums
    
    means.sums.cmp <- merge.cxs(comparisons, kind)
    means.cmp <- means.sums.cmp$means
    sums.cmp <- means.sums.cmp$sums

    common.genes <- intersect(means.tgt$gene, means.cmp$gene)
    means.tgt <- filter(means.tgt, gene %in% common.genes)
    means.cmp <- filter(means.cmp, gene %in% common.genes)
    sums.tgt <- filter(sums.tgt, gene %in% common.genes)
    sums.cmp <- filter(sums.cmp, gene %in% common.genes)
      
    x <- inner_join(
      inner_join(means.tgt, means.cmp, by='gene') %>% setNames(c('gene','target.u','comparison.u')),
      inner_join(sums.tgt, sums.cmp, by='gene') %>% setNames(c('gene','target.sum','comparison.sum')), by='gene')
    
    if (!is.null(progress)) progress$set(value=0.6, detail=glue("Fold ratios, p-vals and conf ints for {nrow(x)} genes"))
    
    ## binom tests are subtly different here. The pval is calculated
    ## based on how far target.sum is from
    ## sum(target.sum)/(sum(target.sum)+sum(comparison.sum)), i.e. the
    ## expected random counts based on the size of the two sets if
    ## there was no difference in expression.
    ##
    ## The L and R confidence are NOT based on the range of probable
    ## counts for target.sum IF target.sum/(target.sum+comparison.sum)
    ## is the true proportion probability. (Seemed like a good idea to me.)
    ##
    ## Instead, the confidence is only related to the size of the
    ## target set. Smaller sets have larger CI when normalized to a
    ## common size pool.  E.g., the target may contain 100,000
    ## transcripts total. And 100 genes might be observed for gene
    ## G. Assuming that the true proportion of G among all the other
    ## genes in the target cluster is .1% (100/100,000), then a
    ## binomial distribution with p=0.001 and N=100000 implies a range
    ## of qbinom(c(0.025,0.975), 100000, 0.001) == [81, 120] for the
    ## 95% confidence interval. But if the total in the target cluster
    ## is N=1000 and observed count of 1, then qbinom(c(0.025,0.975,
    ## 1000, 0.001) == [0,3]. When scaled to a common cluster size of
    ## 100,000 transcripts, then the range is [0,300]. In this way,
    ## we can compare relative expression levels, but represent the
    ## uncertainty based on the target size.

    target.total <- sum(x$target.sum)
    scale.per.100k <- 100000/target.total

    x <- mutate(x, 
                log.target.u=log.transform(target.u), 
                log.comparison.u=log.transform(comparison.u),
                pval=edgeR::binomTest(target.sum, comparison.sum),
                fc=log.target.u-log.comparison.u, 
                fc.disp=exp(fc),
                target.sum.L=qbinom(0.025, target.total, target.sum/target.total),
                target.sum.R=qbinom(0.975, target.total, target.sum/target.total),
                target.sum.per.100k=target.sum*scale.per.100k,
                target.sum.L.per.100k=target.sum.L*scale.per.100k,
                target.sum.R.per.100k=target.sum.R*scale.per.100k)

    if (!is.null(progress)) progress$set(0.8, detail=glue("Cacheing pairwise data"))
    
    saveRDS(x, file=cache.file)
  }
  x
}
