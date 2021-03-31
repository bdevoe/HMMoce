#' Calculate bt-based likelihood in parallel
#' 
#' \code{calc.bottomTemp.par} compares tag-measured bottom temperature to a bottom temperature grid and calculates 
#' likelihoods in parallel
#' 
#' @param tag.bt is data frame containing tag-collected bottom temperature data. Requires at least cols: Date (POSIXct), Temperature
#' @param filename is the first part of the filename specified to the download 
#'   function \code{\link{get.env}}. For example, if downloaded files were 
#'   specific to a particular dataset, you may want to identify that with a name
#'   like 'tuna' or 'shark1'. This results in a downloaded filename of, for 
#'   example, 'tuna_date.nc'. This filename is required here so the calc 
#'   function knows where to get the env data.
#' @param bt.dir local directory where bottom temp nc grids are stored
#' @param dateVec is vector of POSIXct dates for each time step of the likelihood
#' @param focalDim is integer for dimensions of raster::focal used to calculate 
#'   sd() of env grid cell. If left to NULL (default), this dimension will
#'   approximately incorporate 0.25 degrees.
#' @param sens.err is numeric indicating the percent sensor error in the tag bottom temp
#'   sensor. Default is 1.
#' @param varName is name of temperature variable in the bottom temperature nc grids. Default is "Temperature".
#' @param ncores is integer indicating number of cores used in this parallel
#'  computation. Defaults to using a detection function that chooses cores for
#'  you.
#'   
#' @return likelihood is raster brick of likelihood surfaces representing
#'   matches between tag-based bottom temperature and environmental bottom temperature grids
#'   
#' @export
#' 
#' @seealso \code{\link{calc.sst.par}}
#'   

calc.bottomTemp.par <- function(tag.bt, filename, bt.dir, dateVec, focalDim = NULL, sens.err = 1, varName = 'water_temp', ncores = NULL){
  
  print(paste('Starting bottom temperature likelihood calculation...'))
  
  if (is.null(ncores)) ncores <- ceiling(parallel::detectCores() * .9)
  if (is.na(ncores) | ncores < 0) ncores <- ceiling(as.numeric(system('nproc', intern=T)) * .9)
  
  t0 <- Sys.time()
  
  if (class(tag.bt$Date)[1] != class(dateVec)[1]) stop('dateVec and tag.sst$Date both need to be of class POSIXct.')

  tag.bt <- tag.bt[which(tag.bt$Date <= max(dateVec)),]
  tag.bt$dateVec <- findInterval(tag.bt$Date, dateVec)
  tag.bt <- data.frame(tag.bt %>% group_by(dateVec) %>% 
                         dplyr::summarise(minT = min(Temperature, na.rm=T), maxT = max(Temperature, na.rm=T), .groups = 'drop_last'))
  
  T <- length(dateVec)
  
  print(paste('Starting iterations through deployment period ', '...'))
  
  # GET EVERYTHING SETUP BEFORE PARALLEL
  time1 <- tag.bt$time[1]
  bt1 <- c(tag.bt$minT[1] * (1 - sens.err), tag.bt$maxT[1] * (1 + sens.err)) # sensor error
  
  # open day's bt data
  nc1 <- RNetCDF::open.nc(paste(bt.dir, filename, '_', as.Date(dateVec[tag.bt$dateVec[1]]), '.nc', sep='')) #add lat lon in filename '.nc', sep=''))
  
  # get correct name in bt data
  ncnames = NULL
  nmax <- RNetCDF::file.inq.nc(nc1)$nvars - 1
  for(ii in 0:nmax) ncnames[ii + 1] <- RNetCDF::var.inq.nc(nc1, ii)$name
  nameidx <- grep(varName, ncnames, ignore.case = TRUE) - 1
  dat <- RNetCDF::var.get.nc(nc1, nameidx)
  lon <- RNetCDF::var.get.nc(nc1, 'lon')
  lat <- RNetCDF::var.get.nc(nc1, 'lat')
  
  # result will be array of likelihood surfaces
  L.bt <- array(0, dim = c(length(lon), length(lat), length(dateVec)))
  
  # calc sd of bt
  # focal calc on mean temp and write to sd var
  r = raster::flip(raster::raster(t(as.matrix(dat)), xmn=min(lon), xmx=max(lon),
                                  ymn=min(lat), ymx=max(lat)), 2)
  
  # check for coarse enough resolution that our calculations wont take all day
  if(round(raster::res(r)[1], 2) < 0.1){
    aggFact <- round(0.1 / round(raster::res(r)[1], 2), 0)
    if(aggFact > 1) r <- raster::aggregate(r, fact = aggFact)
  } 
  
  # set up a focal() dimension if not specified by user, we use this for sd() of surround 0.25deg worth of grid cells
  if(is.null(focalDim)){
    focalDim <- round(0.25 / raster::res(r)[1], 0)
    if(focalDim %% 2 == 0) focalDim <- focalDim - 1
    if (focalDim == 1) focalDim <- 3 ## if this equals 1, weird things happen
  }
  
  # calculate sd from bt grid using focal()
  sdx = raster::focal(r, w = matrix(1, nrow = focalDim, ncol = focalDim), fun = function(x) stats::sd(x, na.rm = T), pad = TRUE)
  sdx = t(raster::as.matrix(raster::flip(sdx, 2)))
  dat <- base::t(raster::as.matrix(raster::flip(r, 2)))
  
  # get aggregated version of lat/lon for raster creation later
  lon.agg <- seq(raster::extent(r)[1], raster::extent(r)[2], length.out=dim(r)[2])
  lat.agg <- seq(raster::extent(r)[3], raster::extent(r)[4], length.out=dim(r)[1])
  

  ## END of SETUP RUN
  
  print('Processing in parallel... ')
  
  cl = parallel::makeCluster(ncores)
  doParallel::registerDoParallel(cl, cores = ncores)
  
  ans = foreach::foreach(i = 1:T) %dopar%{
    
  #for(i in 1:T){
    
    print(dateVec[i])
    
    # tag data for this time step T
    tag.bt.i <- tag.bt[which(tag.bt$dateVec == i),]
    if (nrow(tag.bt.i) == 0) return(NA)
    
    bt.i <- c(tag.bt.i$minT * (1 - sens.err / 100), tag.bt.i$maxT * (1 + sens.err / 100)) # sensor error
    
    # open day's bt data
    nc <- RNetCDF::open.nc(paste(bt.dir, filename, '_', as.Date(dateVec[i]), '.nc', sep='')) #add lat lon in filename '.nc', sep=''))
    dat <- RNetCDF::var.get.nc(nc, nameidx) # for OI bt
    
    # calc sd of bt
    # focal calc on mean temp and write to sd var
    r <- raster::flip(raster::raster(t(as.matrix(dat)), xmn=min(lon), xmx=max(lon),
                                     ymn=min(lat), ymx=max(lat)), 2)
    
    if(round(raster::res(r)[1], 2) < 0.1){
      aggFact <- round(0.1 / round(raster::res(r)[1], 2), 0)
      if(aggFact != 1) r <- raster::aggregate(r, fact = aggFact)
    } 
    
    sdx = raster::focal(r, w = matrix(1, nrow = focalDim, ncol = focalDim), fun = function(x) stats::sd(x, na.rm = TRUE))
    sdx = t(raster::as.matrix(raster::flip(sdx, 2)))
    
    dat <- base::t(raster::as.matrix(raster::flip(r, 2)))
    
    # compare bt to env grid
    lik.bt <- likint3(dat, sdx, bt.i[1], bt.i[2])
    
    #idx <- which(dateVec == time)
    #L.bt[,,idx] = lik.bt / max(lik.bt, na.rm=T)
    
    lik.bt
  }
  
  parallel::stopCluster(cl)
  
  #lapply
  lik.bt <- lapply(ans, function(x) x / max(x, na.rm = T))
  
  for (i in 1:T){
    L.bt[,,i] <- lik.bt[[i]]
  }
  
  print(paste('Making final likelihood raster...'))
  
  crs <- "+proj=longlat +datum=WGS84 +ellps=WGS84"
  list.bt <- list(x = lon.agg, y = lat.agg, z = L.bt)
  #ex <- raster::extent(list.bt)
  #L.bt <- raster::brick(list.bt$z, xmn=ex[1], xmx=ex[2], ymn=ex[3], ymx=ex[4], transpose=T, crs)
  #L.bt <- raster::flip(L.bt, direction = 'y')
  
  #L.bt[L.bt < 0] <- 0
  
  #names(L.bt) <- as.character(dateVec)
  
  t1 <- Sys.time()
  print(paste('Bottom temperature calculations took ', round(as.numeric(difftime(t1, t0, units='mins')), 2), 'minutes...'))
  
  # return bt likelihood surfaces
  #return(L.bt)
  return(list.bt)
  
}
