# shellcheck shell=bash
#about-alias 'docker abbreviations'

alias dc='docker'
alias dclc='docker ps -l'                                                            # List last Docker container
alias dclcid='docker ps -l -q'                                                       # List last Docker container ID
alias dclcip='docker inspect -f "{{.NetworkSettings.IPAddress}}" $(docker ps -l -q)' # Get IP of last Docker container
alias dcps='docker ps'                                                               # List running Docker containers
alias dcpsa='docker ps -a'                                                           # List all Docker containers
alias dci='docker images'                                                            # List Docker images
alias dcrmac='docker rm $(docker ps -a -q)'                                          # Delete all Docker containers

case $OSTYPE in
	darwin* | *bsd* | *BSD*)
		alias dcrmui='docker images -q -f dangling=true | xargs docker rmi' # Delete all untagged Docker images
		;;
	*)
		alias dcrmui='docker images -q -f dangling=true | xargs -r docker rmi' # Delete all untagged Docker images
		;;
esac

if declare -F _bash-it-component-item-is-enabled > /dev/null \
	&& _bash-it-component-item-is-enabled plugin docker; then
	# Function aliases from docker plugin:
	alias dcrmlc='docker-remove-most-recent-container' # Delete most recent (i.e., last) Docker container
	alias dcrmall='docker-remove-stale-assets'         # Delete all untagged images and exited containers
	alias dcrmli='docker-remove-most-recent-image'     # Delete most recent (i.e., last) Docker image
	alias dcrmi='docker-remove-images'                 # Delete images for supplied IDs or all if no IDs are passed as arguments
	alias dcideps='docker-image-dependencies'          # Output a graph of image dependencies using Graphiz
	alias dcre='docker-runtime-environment'            # List environmental variables of the supplied image ID
fi
alias dcelc='docker exec -it $(dklcid) bash --login' # Enter last container (works with Docker 1.3 and above)
alias dcrmflast='docker rm -f $(dklcid)'
alias dcbash='dkelc'
alias dcex='docker exec -it ' # Useful to run any commands into container without leaving host
alias dcri='docker run --rm -i '
alias dcric='docker run --rm -i -v $PWD:/cwd -w /cwd '
alias dcrit='docker run --rm -it '
alias dcritc='docker run --rm -it -v $PWD:/cwd -w /cwd '

# Added more recent cleanup options from newer docker versions
alias dcip='docker image prune -a -f'
alias dcvp='docker volume prune -f'
alias dcsp='docker system prune -a -f'
