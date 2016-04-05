###############  Prepare for Coverage ######################

## helper function to prepare coverage and gc data
## given a GRange object and bam file, calculate average coverage for each range
## a helper function for 'getCoverage()' function
calculateSubCoverage = function(range, bam){
  ## read bam file from given ranges,
  ## filter out duplicated reads, secondary reads and unmapped reads
  param = ScanBamParam(flag=scanBamFlag(isUnmappedQuery=FALSE, 
                                        isSecondaryAlignment=FALSE, 
                                        isDuplicate=FALSE),
                       which=range)
  ## read alignment
  sub_alignment = readGAlignments(bam,param=param)
  ## calculate coverage
  cov = GenomicAlignments::coverage(sub_alignment)
  cov = cov[range]
  ## return average coverage for each region
  round(mean(cov))
}

## helper function to prepare coverage and gc data
## given the path to targeted bed file and bam file, 
## create a GRanges object containing coverage for each targeted region
getCoverage = function(bam, target_bed, genome_assembly="hg19"){
  ## read in target bed table
  target = read.table(target_bed,sep="\t",header=F)
  ## prepare GRanges object for input bed file
  target_gr = GenomicRanges::GRanges(seqnames=Rle(target[,1]), 
                                     ranges=IRanges(start=target[,2]+1,
                                                    end=target[,3]),
                                     strand=rep("*",nrow(target)))
  #seqinfo = Seqinfo(genome=genome_assembly)[seqlevels(target_gr)]
  #seqinfo(target_gr) = seqinfo
  nRegion = length(target_gr)
  cat(paste(nRegion, "regions from", length(seqlevels(target_gr)),
            "chromosomes in the bed file.", sep=" "))
  
  ## use helper function to calculate average coverage for each region, 
  ## in order to handle large bam files, 
  ## process 1000 regions at a time to reduce memory usage
  message("calculating depth from BAM...")
  depth = NULL
  for (i in seq(1,nRegion,1000)){
    ## report progress
    if(i%%5000==1&i>1) cat(paste(i-1,"regions processed\n"))
    end = ifelse(i+999>nRegion,nRegion,i+999)
    sub_depth = calculateSubCoverage(target_gr[i:end],bam)
    depth = c(depth, sub_depth)
  }
  ## see if number of depth equals to number of regions
  if (length(depth) == nRegion) mcols(target_gr)$depth = depth
  else stop(paste("with", nRegion, "target regions, only", 
                  length(depth), "processed. Please check your input.",
                  sep=" "))
  target_gr
}


## helper function to prepare gc data
## given target region as a GRanges object, calculate gc content for each range
calculateGC = function(range,genome_assembly="hg19"){
  genome = getBSgenome(genome_assembly)
  ## use alphabetFrequency function in biostring to calculate GC percent
  message("calculating GC content...")
  base_frequency = alphabetFrequency(BSgenomeViews(genome,range),
                                     as.prob = T)[,c("C","G")]
  gc_content = apply(base_frequency,1,sum)
  gc_content
}


## helper function to quantile normalize coverage if there is >1 sample
## given a GRangesList, normalize the coverage by quantile normalization
coverageQuantile = function(object){
  message(paste("Quantile normalizing ..."))
  nSample = length(object)
  sample_name = names(object)
  all_cov = NULL
  for (i in 1:nSample){
    all_cov = cbind(all_cov,mcols(object[[i]])$depth)
  }
  all_quantile = round(normalize.quantiles(all_cov))
  res = NULL
  for (i in 1:nSample){
    sub_res = object[[i]]
    mcols(sub_res)$quantiled_depth = all_quantile[,i]
    if (is.null(res)) res = GRangesList(sub_res)
    else
      res = c(res,GRangesList(sub_res))
  }
  names(res) = sample_name
  res
}

## helper function to correct coverage by GC content
## given a GRanges object, output corrected coverage
correctGCBias = function(object,plot=T){
  ## correct coverage by GC content
  ## convert GRanges object to frame
  gc_depth = as.data.frame(object)
  name = names(gc_depth)
  
  ## check if data has been quantile normalized
  ## if data has been quantile normalized, the following analysis is operated
  ## on quantiled depth
  quantiled = F
  if (is.element("quantiled_depth",name)){
    ## exclude regions with 0 coverage
    quantiled = T
    gc_depth = gc_depth[gc_depth$depth>0&gc_depth$quantiled_depth>0,]
    names(gc_depth) = sub("quantiled_depth","coverage",name)
  }
  else{
    gc_depth = gc_depth[gc_depth$depth>0,]
    names(gc_depth) = sub("depth","coverage",name)
  }
  
  ## round gc content to 0.001 increments
  gc_depth = data.frame(gc_depth,round_gc=round(gc_depth$GC,3))
  ## split data by GC content
  split_gc = split(gc_depth,gc_depth$round_gc)
  coverage_by_gc = sapply(split_gc,function(x)mean(x$coverage,na.rm=T))
  gc_coverage = data.frame(round_gc = as.numeric(names(coverage_by_gc)),
                           mean_reads = coverage_by_gc)
  ## fit coverage and GC content by loess
  gc_coverage_fit = loess(gc_coverage$mean_reads~gc_coverage$round_gc,span=0.5)
  ## the expected coverage is the mean of the raw coverage
  expected_coverage = mean(gc_depth[,"coverage"])
  
  ## plot GC vs. raw reads plot
  if(plot == T){
    plot(x = gc_coverage$round_gc, 
         y = gc_coverage$mean_reads, 
         pch = 16, col = "blue", cex = 0.6, 
         ylim = c(0,1.5*quantile(gc_coverage$mean_reads,0.95,na.rm=T)),
         xlab = "GC content", ylab = "raw reads", 
         main = "GC vs Coverage Before Norm",cex.main=0.8)
    lines(gc_coverage$round_gc, 
          predict(gc_coverage_fit, gc_coverage$round_gc), 
          col = "red", lwd = 2)
    abline(h = expected_coverage, lwd = 2, col = "grey", lty = 3)
  }
  
  ## correct reads by loess fit
  normed_coverage = NULL
  for (i in 1:24){
    ## check if the coordinate is with "chr" or not
    if(nchar(as.character(seqnames(object)@values[1]))>3) {
      chr = paste("chr",i,sep="")
      if (i == 23) chr = "chrX"
      if (i == 24) chr = "chrY"
    }
    else{
      chr = i
      if (i == 23) chr = "X"
      if (i == 24) chr = "Y"
    }
    tmp_chr = gc_depth[gc_depth$seqnames == chr,]
    if(nrow(tmp_chr)==0) next
    chr_normed = NULL
    for (j in 1:nrow(tmp_chr)){
      tmp_coverage = tmp_chr[j,"coverage"]
      tmp_GC = tmp_chr[j,"GC"]
      # predicted read from the loess fit
      tmp_predicted = predict(gc_coverage_fit, tmp_GC)
      # calculate the error biased from expected
      tmp_error = tmp_predicted - expected_coverage
      tmp_normed = tmp_coverage - tmp_error
      chr_normed = c(chr_normed, tmp_normed)
    }
    normed_coverage = c(normed_coverage,chr_normed)
  }
  gc_depth = cbind(gc_depth,normed_coverage = normed_coverage)
  gc_depth = gc_depth[!is.na(gc_depth$normed_coverage),]
  
  ## calculate and plot GC vs coverage after normalization
  split_gc_after = split(gc_depth,gc_depth$round_gc)
  coverage_by_gc_after = sapply(split_gc_after,
                                function(x)mean(x$normed_coverage,na.rm=T))
  gc_coverage_after = data.frame(round_gc=as.numeric(names(coverage_by_gc_after)),
                                 mean_reads=coverage_by_gc_after)
  gc_coverage_fit_after = loess(gc_coverage_after$mean_reads
                                ~gc_coverage_after$round_gc,span=0.5)
  
  ## plot GC vs coverage after normalization
  if (plot == T){
    plot(x = gc_coverage_after$round_gc, 
         y = gc_coverage_after$mean_reads, 
         pch = 16, col = "blue", cex = 0.6, 
         ylim = c(0,1.5*quantile(gc_coverage_after$mean_reads,0.95,na.rm=T)),
         xlab = "GC content", ylab = "normalized reads", 
         main = "GC vs Coverage After Norm",cex.main=0.8)
    lines(gc_coverage_after$round_gc, 
          predict(gc_coverage_fit_after, gc_coverage_after$round_gc), 
          col = "red", lwd = 2)
  }
  
  ## round normalized coverage to integer
  gc_depth$normed_coverage = round(gc_depth$normed_coverage)
  ## exclude regions with corrected coverage <0
  gc_depth = gc_depth[gc_depth$normed_coverage>0,]
  
  ## convert gc_depth into a GRanges object
  if (quantiled == T){
    res = GRanges(seqnames = Rle(gc_depth$seqnames), 
                  ranges = IRanges(start=gc_depth$start,end=gc_depth$end),
                  strand = rep("*",nrow(gc_depth)),
                  depth = gc_depth$depth,
                  quantiled_depth = gc_depth$coverage,
                  GC = gc_depth$GC,
                  normed_depth = gc_depth$normed_coverage)
  }
  else{
    res = GRanges(seqnames = Rle(gc_depth$seqnames), 
                  ranges = IRanges(start=gc_depth$start,end=gc_depth$end),
                  strand = rep("*",nrow(gc_depth)),
                  depth = gc_depth$coverage,
                  GC = gc_depth$GC,
                  normed_depth = gc_depth$normed_coverage)
  }
  res
}


## function to calculate mean coverage for each chromosome after normalization
## and could plot out the coverage before and after normalization
## input: a GRangesList object
calculateNormedCoverage = function(object,plot=T){
  ## check if the coordinate is with "chr" or not
  if(nchar(as.character(seqnames(object[[1]])@values[1]))>3){
    chr_order = c("chr1","chr2","chr3","chr4","chr5","chr6","chr7","chr8",
                 "chr9","chr10","chr11","chr12","chr13","chr14","chr15",
                 "chr16","chr17","chr18","chr19","chr20","chr21","chr22",
                 "chrX","chrY")
    chr_name = seqlevels(object)
    chr_name = chr_name[match(chr_order,chr_name)]
    chr_name = chr_name[!is.na(chr_name)]
  }
  else{
    chr_order = c("1","2","3","4","5","6","7","8","9","10","11","12",
                 "13","14","15","16","17","18","19","20","21","22","X","Y")
    chr_name = seqlevels(object)
    chr_name = chr_name[match(chr_order,chr_name)]
    chr_name = chr_name[!is.na(chr_name)]
  }
  
  nSample = length(object)
  sample_name = names(object)
  split_object = sapply(object,function(x)split(x,seqnames(x)))
  
  ## calculate average coverage for each chromosome after normalization
  after_chr = NULL
  for (i in 1:nSample){
    sub_after_chr = sapply(split_object[[i]],
                           function(x)mean(mcols(x)$normed_depth))
    after_chr = rbind(after_chr,sub_after_chr[chr_name])
  }
  rownames(after_chr) = sample_name
  
  ## if plot requested, then plot 
  if (plot == T){
    par(mfrow=c(ifelse(nSample>1,3,2),1))
    ## calculate average coverage before normalization
    before_chr = NULL
    quantiled_chr = NULL
    for (i in 1:nSample){
      sub_before_chr = sapply(split_object[[i]],
                              function(x)mean(mcols(x)$depth))
      before_chr = rbind(before_chr,sub_before_chr[chr_name])
      if (nSample>1){
        sub_quantiled_chr = sapply(split_object[[i]],
                                   function(x)mean(mcols(x)$quantiled_depth))
        quantiled_chr = rbind(quantiled_chr,sub_quantiled_chr[chr_name])
      }
    }
    ## plot
    cols = sample(colors(),nSample)
    nChr = ncol(after_chr)
    ## 1. plot raw coverage
    plot(1:nChr,rep(1,nChr),type="n",
         ylim=c(0.5*min(before_chr),1.5*max(before_chr)),
         xlab="chromosome",ylab="average coverage",main = "raw data",xaxt="n")
    axis(1,at=seq(1,nChr),chr_name[1:nChr],las=2)
    for (i in 1:nSample){
      lines(1:nChr,before_chr[i,],type="b",pch=16,col=cols[i])
    }
    legend("topright",sample_name,pch=16,col=cols)
    
    if(nSample>1){
      ## 2. plot quantiled coverage
      plot(1:nChr,rep(1,nChr),type="n",xaxt="n",
           ylim=c(0.5*min(quantiled_chr),1.5*max(quantiled_chr)),
           xlab="chromosome",ylab="average coverage",main="quantile normalized")
      axis(1,at=seq(1,nChr),chr_name[1:nChr],las=2)
      for (i in 1:nSample){
        lines(1:nChr,quantiled_chr[i,],type="b",pch=16,col=cols[i])
      }
      legend("topright",sample_name,pch=16,col=cols)
    }
    
    ## 3. plot normed coverage
    plot(1:nChr,rep(1,nChr),type="n",xaxt="n",
         ylim=c(0.5*min(after_chr),1.5*max(after_chr)),
         xlab="chromosome",ylab="average coverage",main="GC normalized")
    axis(1,at=seq(1,nChr),chr_name[1:nChr],las=2)
    for (i in 1:nSample){
      lines(1:nChr,after_chr[i,],type="b",pch=16,col=cols[i])
    }
    legend("topright",sample_name,pch=16,col=cols)
  }
  after_chr
}


######################## Prepare for AAF ##########################
## filters set for vcf file
isHetero = function(x){
  genotype = geno(x)$GT
  genotype == "0/1" | genotype == "1/0"
}