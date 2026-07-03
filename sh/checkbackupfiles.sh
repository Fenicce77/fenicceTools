#!/bin/bash
# Author : Ricardo Mateos Calcines
# Desc : Script for syncying MySQL slave after 1032 error in a non multisource replica
# output colours
blk=$(tput blink)
bld=$(tput bold)                 # Bold
red=${bld}$(tput setaf 1)    # Red
grn=${bld}$(tput setaf 2)    # Green
yel=${bld}$(tput setaf 3)    # Yellow
blu=${bld}$(tput setaf 4)    # Blue
mag=${bld}$(tput setaf 5)    # Purple
cyn=${bld}$(tput setaf 6)    # Cyan
wht=${bld}$(tput setaf 7)    # White
off=$(tput sgr0)             # Text reset

DBLIST="www_allcasino_com www_americasline_com www_bestonlinegambling_com www_betmoneyonline_com www_casinoslots_com www_casinosouthafrica_com www_miamicasinoclub_com www_realmoneygambling_org www_slots_ca www_usracebook_com"

for db in $DBLIST; do
        echo "${yel} Checking ${db}... ${off}"
        lastf=`ls ${db} | tail -1`
        for fcom in `ls ${db} | head -4`; 
        do 
        	echo "${cyn}Comparing ${db}/${lastf} and ${db}/${fcom} ${off}"
        	zdiff -u "${db}/${lastf}" "${db}/${fcom}"; 
        done

done