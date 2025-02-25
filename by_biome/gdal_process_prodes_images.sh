#!/bin/bash
#
# https://gdal.org/drivers/raster/gtiff.html
# GDAL_NUM_THREADS enables multi-threaded compression by specifying the number of worker threads.
# Worth it for slow compression algorithms such as DEFLATE or LZMA. Will be ignored for JPEG.
# Default is compression in the main thread. Note: this configuration option also apply to other
# parts to GDAL (warping, gridding, ...). Starting with GDAL 3.6, this option also enables multi-threaded
# decoding when RasterIO() requests intersect several tiles/strips.
export GDAL_NUM_THREADS=ALL_CPUS

# NOTE: change nodata value to 0, projection to EPSG: 4326, and merge scenes as a mosaic.

year=$1
biome=$2
data_dir=$3

TODAY_DATE=$(date '+%Y%m%d')
echo
echo "----- Testing input parameters  ${TODAY_DATE} -----"

# verify parameter
if [ "$#" -eq 3 ]
then
  if [[ -v year && -v biome && -v data_dir ]];
  then
    echo "Parameter year=${year}"
    echo "Parameter biome=${biome}"
    echo "Parameter data_dir=${data_dir}"
    echo "Mandatory parameters are defined. Let's test it."
  fi;
else
  CURRENT_YYYY=$(date '+%Y')
  echo "Insert a parameters:"
  echo " - with year YYYY;"
  echo " - the biome name like: amazonia or mata_atlantica;"
  echo " - the location directory where the input files are;"
  echo 
  echo "Example: ./gdal_process_prodes_images.sh ${CURRENT_YYYY} cerrado /pve12/share/cerrado/2023"
  echo
  exit 1
fi;

# get location where the script is
SCRIPT_LOCATION=$( dirname -- "$( readlink -f -- "$0"; )"; )
echo "where script file is: ${SCRIPT_LOCATION}"

if [[ ! -f "${SCRIPT_LOCATION}/../lib/functions.sh" ]];
then
  echo "Functions not found, aborting..."
  exit 1
fi;

cd ${SCRIPT_LOCATION}/../lib/
. ./functions.sh
cd -

# test if data dir has some tif file
FOUNDED_FILES=$(hasTiffFiles "${data_dir}")
echo "Searching tif files in: ${data_dir}"
if [[ ${FOUNDED_FILES} -gt 0 ]];
then
  echo "Input tif files found, proceeding..."
  echo "More details on log file: ${data_dir}/output_mosaic_${year}_${TODAY_DATE}.log"
else
  echo "Input tif files not found, aborting..."
  echo "Edit this script and set the correct location of input tif files."
  exit 1
fi;

exec > ${data_dir}/output_mosaic_${year}_${TODAY_DATE}.log 2>&1

echo "Test location of shapefiles as grid and biome border"
echo
## AMZ LEGAL
shapefile="${SCRIPT_LOCATION}/../shapefiles/limite_${biome}/${biome}_border_new_ibge_4326.shp" # <- CHANGE ME
fileExistsOrExit "${shapefile}"

shapefile_grid="${SCRIPT_LOCATION}/../shapefiles/limite_${biome}/grid_landsat_${biome}_new_ibge_4326.shp" # <- CHANGE ME
fileExistsOrExit "${shapefile_grid}"

rscript_file="${SCRIPT_LOCATION}/script_r_cut_images_by_grid.R" # <- CHANGE ME
fileExistsOrExit "${rscript_file}"

shopt -s nocasematch

echo "Starting process: `date +%d-%m-%y_%H:%M:%S`"
echo
echo "----- gdal copy -----"
echo

cd ${data_dir}
dir=tempCopy
mkdir -p $dir
echo "Copying files to: ${dir}"

for file in *.tif; do
  filename=$(getFilename "${file}")
  extension=$(getExtension "${file}")
  gdalmanage copy "$file" "${dir}/${filename}_copy.${extension}"
done

echo "End of copying files: `date +%d-%m-%y_%H:%M:%S`"

echo
echo "----- gdal unset NoData -----"
echo
cd ${dir}

for file in *.tif; do
  gdal_edit.py "$file" -unsetnodata
done

echo "End of unset NoData: `date +%d-%m-%y_%H:%M:%S`"

echo
echo "----- gdal reproject to EPSG:4326 -----"
echo

dir=tempEPSG4326
mkdir -p $dir

for file in *.tif; do
  filename=$(getFilename "${file}")
  extension=$(getExtension "${file}")

  # read the source projection from input file
  SOURCE_SRC=""
  SRC_TEST="$(gdalinfo "${file}" 2>/dev/null | grep -oP 'GEOGCRS\["unknown",')"
  if [[ " GEOGCRS[\"unknown\", " = " ${SRC_TEST} " ]]; then
    # if is unknown so force the EPSG: 4674 (used on Cerrado imagens and need to be reviw for other biomes)
    echo "WARNING: found unknown projection for: ${file}"
    echo "WARNING: force geographical/SIRGAS 2000 (EPSG:4674) as INPUT projection."
    SOURCE_SRC="-s_srs EPSG:4674"
  fi;

  gdalwarp -of GTiff $SOURCE_SRC -t_srs "EPSG:4326" "$file" "${dir}/${filename}_4326.${extension}"
done

echo "End of reproject to EPSG:4326: `date +%d-%m-%y_%H:%M:%S`"

echo
echo "----- Cut band to bounding line -----"
echo

cd ${dir}

raster_dir="$(pwd)/"
echo "$raster_dir"

function Rscript_with_status {
  # shapefile_grid expect the path and full name of shapefile with grid for biome
  # raster_dir expect the path when tif files are. These tifs should be reprojected to EPSG:4326
  if Rscript --vanilla ${rscript_file} ${shapefile_grid} "${raster_dir}"
  then
    echo -e "0"
    echo
    echo "End of image cropping by biome grid: `date +%d-%m-%y_%H:%M:%S`"
    return 0
  else
    echo -e "1"
    echo
    echo "ERROR: Something is wrong on R script."
    echo "End of image cropping by biome grid: `date +%d-%m-%y_%H:%M:%S`"
    exit 1
  fi
}
Rscript_with_status

echo
echo "----- gdal Remove Band Alpha -----"
echo
# go to the directory crated by the Rscript
cd tempCutted_buffer/
dir=tempNoAlphaBand
mkdir -p $dir

for file in *.tif; do
  filename=$(getFilename "${file}")
  extension=$(getExtension "${file}")
  gdal_translate -b 1 -b 2 -b 3 -of GTiff "$file" "${dir}/${filename}_noalpha.${extension}"
done

echo "End of remove alpha band: `date +%d-%m-%y_%H:%M:%S`"

echo
echo "----- gdal set NoData for no alpha band files -----"
echo
cd tempNoAlphaBand/
dir=tempNoData
mkdir -p $dir

for file in *.tif; do
  filename=$(getFilename "${file}")
  extension=$(getExtension "${file}")
  gdalwarp -of GTiff -t_srs EPSG:4326 -srcnodata "255 255 255" -dstnodata "0 0 0" "$file" "${dir}/${filename}_nodata.${extension}"
done

echo "End of set NoData for no alpha band files: `date +%d-%m-%y_%H:%M:%S`"

echo "----- move result dir to base dir and remove temporary dirs and files -----"
mv ${data_dir}/tempCopy/tempEPSG4326/tempCutted_buffer/tempNoAlphaBand/tempNoData/ ${data_dir}
rm -rf ${data_dir}/tempCopy/
echo

echo "----- merge all scenes -----"
gdal_merge.py -n 0 -a_nodata 0 -of GTiff -o ${data_dir}/mosaic_${year}_border.tif ${data_dir}/tempNoData/*.tif
echo
echo "End of merge all scenes: `date +%d-%m-%y_%H:%M:%S`"

echo
echo "----- gdal cutline -----"
gdalwarp -ot Byte -q -of GTiff -srcnodata "0 0 0" -dstalpha -cutline ${shapefile} -crop_to_cutline -co BIGTIFF=YES -co COMPRESS=LZW -wo OPTIMIZE_SIZE=TRUE ${data_dir}/mosaic_${year}_border.tif ${data_dir}/mosaic_${year}.tif
echo
echo "End of cutline using shapefile of biome border: `date +%d-%m-%y_%H:%M:%S`"

cd ${data_dir}/
dir=$year
mkdir -p $dir
echo "----- Directory created: ${dir} -----"
echo

echo
echo "----- retile mosaic -----"
gdal_retile.py -v -r bilinear -levels 4 -ps 2048 2048 -ot Byte -co "TILED=YES" -co "COMPRESS=LZW" -targetDir ${year} ${data_dir}/mosaic_${year}.tif
echo

echo "Script has been executed successfully"
echo
echo "THE END: `date +%d-%m-%y_%H:%M:%S`"
