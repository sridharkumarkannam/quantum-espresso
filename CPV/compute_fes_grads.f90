!
! Copyright (C) 2002-2005 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
#include "f_defs.h"
!
!----------------------------------------------------------------------------
SUBROUTINE compute_fes_grads( N_in, N_fin, stat )
  !----------------------------------------------------------------------------
  !
  USE kinds,              ONLY : DP
  USE input_parameters,   ONLY : electron_damping, ekin_conv_thr, etot_conv_thr
  USE wave_base,          ONLY : frice
  USE control_flags,      ONLY : nomore, ldamped, tconvthrs, trane, ampre, &
                                 nbeg, tfor, taurdr, tnosep, ndr, isave
  USE metadyn_vars,       ONLY : ncolvar, new_target, to_target, dfe_acc, &
                                 etot_av, shake_nstep, fe_nstep, to_new_target
  USE path_variables,     ONLY : pos, pes, grad_pes, frozen, &
                                 num_of_images, istep_path, suspended_image
  USE constraints_module, ONLY : lagrange, target, &
                                 init_constraint, deallocate_constraint
  USE cell_base,          ONLY : alat, at
  USE cp_main_variables,  ONLY : nfi
  USE ions_base,          ONLY : tau, nat, nsp, ityp, if_pos, sort_tau, &
                                 tau_srt, ind_srt
  USE path_formats,       ONLY : scf_fmt, scf_fmt_para
  USE io_files,           ONLY : prefix, outdir, iunpath, iunaxsf, &
                                 iunupdate, exit_file, iunexit
  USE constants,          ONLY : bohr_radius_angs
  USE io_global,          ONLY : stdout, ionode, ionode_id, meta_ionode
  USE mp_global,          ONLY : inter_image_comm, intra_image_comm, &
                                 my_image_id, nimage, root
  USE mp,                 ONLY : mp_bcast, mp_barrier, mp_sum, mp_min
  USE check_stop,         ONLY : check_stop_now
  USE input,              ONLY : modules_setup
  USE xml_io_base,        ONLY : check_restartfile
  USE path_io_routines,   ONLY : new_image_init, get_new_image, &
                                 stop_other_images
  USE metadyn_base,       ONLY : add_domain_potential
  USE metadyn_io,         ONLY : write_axsf_file
  !
  IMPLICIT NONE
  !
  INTEGER, INTENT(IN)   :: N_in, N_fin
  LOGICAL, INTENT(OUT)  :: stat
  INTEGER               :: image, iter
  CHARACTER(LEN=256)    :: outdir_saved, filename
  LOGICAL               :: file_exists, opnd
  LOGICAL               :: tnosep_saved
  REAL(DP)              :: tcpu
  REAL(DP), ALLOCATABLE :: tauout(:,:), fion(:,:)
  REAL(DP)              :: etot
  !
  CHARACTER(LEN=6), EXTERNAL :: int_to_char
  REAL(DP),         EXTERNAL :: get_clock
  !
  !
  stat = .TRUE.
  !
  ALLOCATE( tauout( 3, nat ), fion( 3, nat ) )
  !
  ! ... out positions are initialised to the input ones
  !
  tauout(:,:) = tau(:,:)
  !
  CALL flush_unit( iunpath )
  !
  IF ( ionode ) THEN
     !
     OPEN( UNIT = iunaxsf, FILE = TRIM( prefix ) // "_" // &
         & TRIM( int_to_char( istep_path + 1 ) ) // ".axsf", &
           STATUS = "UNKNOWN", ACTION = "WRITE" )
     !
     WRITE( UNIT = iunaxsf, FMT = '(" ANIMSTEPS ",I5)' ) num_of_images
     WRITE( UNIT = iunaxsf, FMT = '(" CRYSTAL ")' )
     WRITE( UNIT = iunaxsf, FMT = '(" PRIMVEC ")' )
     WRITE( UNIT = iunaxsf, FMT = '(3F14.10)' ) &
          at(1,1) * alat * bohr_radius_angs, &
          at(2,1) * alat * bohr_radius_angs, &
          at(3,1) * alat * bohr_radius_angs
     WRITE( UNIT = iunaxsf, FMT = '(3F14.10)' ) &
          at(1,2) * alat * bohr_radius_angs, &
          at(2,2) * alat * bohr_radius_angs, &
          at(3,2) * alat * bohr_radius_angs
     WRITE( UNIT = iunaxsf, FMT = '(3F14.10)' ) &
          at(1,3) * alat * bohr_radius_angs, &
          at(2,3) * alat * bohr_radius_angs, &
          at(3,3) * alat * bohr_radius_angs
     !
  END IF
  !
  outdir_saved  = outdir
  !
  tnosep_saved = tnosep
  !
  ! ... vectors pes and grad_pes are initalized to zero for all images on
  ! ... all nodes: this is needed for the final mp_sum()
  !
  IF ( my_image_id == root ) THEN
     !
     FORALL( image = N_in:N_fin, .NOT. frozen(image) )
        !
        grad_pes(:,image) = 0.D0
        !
     END FORALL     
     !
  ELSE
     !
     grad_pes(:,N_in:N_fin) = 0.D0
     !   
  END IF
  !
  ! ... only the first cpu initializes the file needed by parallelization 
  ! ... among images
  !
  IF ( meta_ionode ) CALL new_image_init( N_in, outdir_saved )
  !
  image = N_in + my_image_id
  !
  ! ... all processes are syncronized (needed to have an ordered output)
  !
  CALL mp_barrier()
  !
  fes_loop: DO
     !
     ! ... exit if available images are finished
     !
     IF ( image > N_fin ) EXIT fes_loop
     !     
     suspended_image = image
     !
     IF ( check_stop_now( iunpath ) ) THEN
        !   
        stat = .FALSE.
        !
        ! ... in case of parallelization on images a stop signal
        ! ... is sent via the "EXIT" file
        !
        IF ( nimage > 1 ) CALL stop_other_images()        
        !
        EXIT fes_loop
        !    
     END IF
     !
     ! ... free-energy gradient ( for non-frozen images only )
     !
     IF ( .NOT. frozen(image) ) THEN
        !
        tcpu = get_clock( 'CP' )
        !
        IF ( nimage > 1 ) THEN
           !
           WRITE( UNIT = iunpath, FMT = scf_fmt_para ) my_image_id, tcpu, image
           !
        ELSE
           !
           WRITE( UNIT = iunpath, FMT = scf_fmt ) tcpu, image
           !
        END IF
        !      
        outdir = TRIM( outdir_saved ) // "/" // TRIM( prefix ) // "_" // &
                 TRIM( int_to_char( image ) ) // "/"        
        !
        ! ... unit stdout is connected to the appropriate file
        !
        IF ( ionode ) THEN
           !
           INQUIRE( UNIT = stdout, OPENED = opnd )
           IF ( opnd ) CLOSE( UNIT = stdout )
           OPEN( UNIT = stdout, FILE = TRIM( outdir ) // 'CP.out', &
                 STATUS = 'UNKNOWN', POSITION = 'APPEND' )
           !
        END IF
        !
        ! ... initialization
        !
        CALL deallocate_modules_var()
        CALL deallocate_constraint()
        !
        CALL modules_setup()
        !
        filename = TRIM( outdir ) // "therm_average.restart"
        !
        INQUIRE( FILE = filename, EXIST = file_exists )
        !
        IF ( file_exists ) THEN
           !
           ! ... if possible we read the previous positions for this image
           ! ... from a restart file
           !
           IF ( ionode ) THEN
              !
              WRITE( stdout, '(/,3X,"restarting pos and vel from file",/)' )
              !
              OPEN( UNIT = 1000, FILE = filename )
              !
              READ( 1000, * ) tau(:,:)
              !
              CLOSE( UNIT = 1000 )
              !
           END IF
           !
           CALL mp_bcast( tau, ionode_id )
           !
        ELSE
           !
           ! ... otherwise we use the output positions for the previous image
           !
           tau(:,:) = tauout(:,:)
           !
        END IF
        !
        CALL sort_tau( tau_srt, ind_srt, tau, ityp, nat, nsp )
        !
        CALL init_constraint( nat, tau, ityp, 1.D0 )
        !
        ! ... first we do a wavefunctions optimisation to bring the system on
        ! ... the BO surface
        !
        tconvthrs%ekin  = ekin_conv_thr
        tconvthrs%derho = etot_conv_thr
        !
        taurdr = .TRUE.
        nfi    = 0
        tnosep = .FALSE.
        tfor   = .FALSE.
        !
        frice = electron_damping
        !
        tconvthrs%active = .TRUE.
        !
        IF ( check_restartfile( outdir, ndr ) ) THEN
           !
           WRITE( stdout, '(/,3X,"restarting from file",/)' )
           !
           nbeg   = 0
           nomore = 50
           !
        ELSE
           !
           WRITE( stdout, '(/,3X,"restarting from scratch",/)' )
           !
           nbeg   = -1
           nomore = 100
           trane  = .TRUE.
           ampre  = 0.02D0
           !
        END IF
        !
        isave = nomore
        !
        CALL init_run()
        !
        CALL cprmain( tauout, fion, etot )
        !
        ! ... the new values of the collective-variables are set here
        !
        new_target(:) = pos(:,image)
        !
        to_target(:) = ( new_target(:) - &
                         target(1:ncolvar) ) / DBLE( shake_nstep )
        !
        ! ... then the system is "adiabatically" moved to the new values of the
        ! ... collective-variables
        !
        WRITE( stdout, '(/,5X,"adiabatic switch of the system ", &
                            & "to the new coarse-grained positions",/)' )
        !
        nfi    = 0
        nomore = shake_nstep
        isave  = nomore
        !
        tfor   = .TRUE.
        frice  = electron_damping
        tnosep = tnosep_saved
        !
        tconvthrs%active = .FALSE.
        to_new_target    = .TRUE.
        !
        IF ( ldamped ) CALL reset_vel()
        !
        CALL cprmain( tauout, fion, etot )
        !
        ! ... and finally the free energy gradients are computed
        !
        WRITE( stdout, '(/,5X,"calculation of the mean force",/)' )
        !
        etot_av = 0.D0
        dfe_acc = 0.D0
        !    
        nfi    = 0
        nomore = fe_nstep
        isave  = nomore
        !
        IF ( ldamped ) THEN
           !
           frice = electron_damping
           !
           tconvthrs%active = .TRUE.
           !
           CALL reset_vel()
           !
        ELSE
           !
           frice = 0.D0
           !
        END IF
        !
        to_new_target = .FALSE.
        !
        CALL cprmain( tauout, fion, etot )
        !
        ! ... the averages are computed here
        !
        IF ( ldamped ) THEN
           !
           ! ... zero temperature
           !
           grad_pes(:,image) = - lagrange(1:ncolvar)
           !
           pes(image) = etot
           !
        ELSE
           !
           ! ... finite temperature
           !
           grad_pes(:,image) = dfe_acc(:) / DBLE( nomore )
           !
        END IF
        !
        IF ( ionode ) THEN
           !
           CALL write_axsf_file( image, tauout, 1.D0 )
           !
           ! ... the restart file is written here
           !
           OPEN( UNIT = 1000, FILE = filename )
           !
           WRITE( 1000, * ) tauout(:,:)
           !
           CLOSE( UNIT = 1000 )
           !
        END IF
        !
     END IF
     !
     ! ... the new image is obtained
     !
     CALL get_new_image( image, outdir_saved )
     !
     CALL mp_bcast( image, ionode_id, intra_image_comm )
     !
  END DO fes_loop
  !
  CLOSE( UNIT = iunaxsf )
  !
  CALL add_domain_potential()
  !
  DEALLOCATE( tauout, fion )
  !
  outdir  = outdir_saved
  !
  tnosep = tnosep_saved
  !
  IF ( nimage > 1 ) THEN
     !
     ! ... grad_pes is communicated among "image" pools
     !
     CALL mp_sum( grad_pes(:,N_in:N_fin), inter_image_comm )
     !
  END IF
  !
  suspended_image = 0
  !
  RETURN  
  !
END SUBROUTINE compute_fes_grads
!
!------------------------------------------------------------------------
SUBROUTINE metadyn()
  !------------------------------------------------------------------------
  !
  USE kinds,              ONLY : DP
  USE input_parameters,   ONLY : electron_damping, ekin_conv_thr, etot_conv_thr
  USE constraints_module, ONLY : target, lagrange
  USE cp_main_variables,  ONLY : nfi
  USE wave_base,          ONLY : frice
  USE control_flags,      ONLY : nomore, ldamped, tconvthrs, tnosep, trane, &
                                 ampre, nbeg, tfor, taurdr, ndr, ndw, isave
  USE ions_base,          ONLY : nat, nsp, ityp, if_pos
  USE io_global,          ONLY : stdout
  USE io_files,           ONLY : iunmeta, iunaxsf, outdir
  USE metadyn_vars,       ONLY : ncolvar, fe_grad, new_target, to_target,   &
                                 metadyn_fmt, to_new_target, fe_step,       &
                                 metadyn_history, max_metadyn_iter,         &
                                 first_metadyn_iter, fe_nstep, shake_nstep, &
                                 dfe_acc, etot_av, gaussian_pos
  USE metadyn_base,       ONLY : add_gaussians, add_domain_potential, &
                                 evolve_collective_vars
  USE metadyn_io,         ONLY : write_axsf_file, write_metadyn_restart
  USE io_global,          ONLY : ionode
  USE xml_io_base,        ONLY : restart_dir, check_restartfile
  USE basic_algebra_routines
  !
  IMPLICIT NONE
  !
  CHARACTER(LEN=256)    :: dirname
  INTEGER               :: iter
  REAL(DP), ALLOCATABLE :: tau(:,:)
  REAL(DP), ALLOCATABLE :: fion(:,:)
  REAL(DP)              :: etot, norm_fe_grad
  LOGICAL               :: do_first_scf
  LOGICAL               :: tnosep_saved
  !
  !
  dirname = restart_dir( outdir, ndw )
  !
  ALLOCATE( tau( 3, nat ), fion( 3, nat ) )
  !
  tnosep_saved = tnosep
  !
  taurdr = .TRUE.
  nfi    = 0
  tfor   = .FALSE.
  !
  tconvthrs%ekin  = ekin_conv_thr
  tconvthrs%derho = etot_conv_thr
  !
  IF ( nbeg == - 1 ) THEN
     !
     WRITE( stdout, '(/,3X,"restarting from scratch",/)' )
     !
     do_first_scf = .TRUE.
     !
     nomore = 200
     trane  = .TRUE.
     ampre  = 0.02D0
     !
     tnosep = .FALSE.
     !
     frice = electron_damping
     !
     tconvthrs%active = .TRUE.
     !
  ELSE IF ( check_restartfile( outdir, ndr ) ) THEN
     !
     WRITE( stdout, '(/,3X,"restarting from file",/)' )
     !
     do_first_scf = .FALSE.
     !
     nbeg = 0
     !
  END IF
  !
  isave = nomore
  !
  CALL init_run()
  !
  IF ( do_first_scf ) THEN
     !
     ! ... first we bring the system on the BO surface
     !
     CALL cprmain( tau, fion, etot )
     !
  END IF
  !
  tfor   = .TRUE.
  tnosep = tnosep_saved
  iter   = first_metadyn_iter
  !
  metadyn_loop: DO
     !
     IF ( iter > 0 ) THEN
        !
        CALL add_gaussians( iter )
        !
        CALL add_domain_potential()
        !
        norm_fe_grad = norm( fe_grad )
        !
        CALL evolve_collective_vars( norm_fe_grad )
        !
        ! ... the system is "adiabatically" moved to the new target
        !
        WRITE( stdout, '(/,5X,"adiabatic switch of the system ", &
                            & "to the new coarse-grained positions",/)' )
        !
        nfi    = 0
        nomore = shake_nstep
        isave  = nomore
        !
        tconvthrs%active = .FALSE.
        to_new_target    = .TRUE.
        !
        frice = electron_damping
        !
        IF ( ldamped ) CALL reset_vel()
        !
        CALL cprmain( tau, fion, etot )
        !
     END IF
     !
     iter = iter + 1
     !
     metadyn_history(:,iter) = gaussian_pos(:)
     !
     IF ( ionode ) CALL write_axsf_file( iter, tau, 1.D0 )
     !
     WRITE( stdout, '(/,5X,"calculation of the mean force",/)' )
     !
     nfi    = 0
     nomore = fe_nstep
     isave  = nomore
     !
     IF ( ldamped ) THEN
        !
        tconvthrs%active = .TRUE.
        !
        frice = electron_damping
        !
        CALL reset_vel()
        !
     ELSE
        !
        frice = 0.D0
        !
     END IF
     !
     to_new_target = .FALSE.
     !
     dfe_acc(:) = 0.D0
     !
     CALL cprmain( tau, fion, etot )
     !
     ! ... the averages are computed here
     !
     IF ( ldamped ) THEN
        !
        ! ... zero temperature
        !
        etot_av = etot
        !
        fe_grad(:) = - lagrange(1:ncolvar)
        !
     ELSE
        !
        ! ... finite temperature
        !
        etot_av = etot_av / DBLE( nomore )
        !
        fe_grad(:) = dfe_acc(:) / DBLE( nomore )
        !
     END IF
     !
     IF ( ionode ) THEN
        !
        WRITE( UNIT = iunmeta, FMT = metadyn_fmt ) &
            iter, target(1:ncolvar), etot_av, gaussian_pos(:), fe_grad(:)
        !
        CALL flush_unit( iunmeta )
        CALL flush_unit( iunaxsf )
        !
     END IF
     !
     CALL write_metadyn_restart( dirname, iter, tau, etot_av, 1.D0 )
     !
     IF ( iter >= max_metadyn_iter ) EXIT metadyn_loop
     !
  END DO metadyn_loop
  !
  IF ( ionode ) THEN
     !
     CLOSE( UNIT = iunaxsf )
     CLOSE( UNIT = iunmeta )
     !
  END IF
  !
  tnosep = tnosep_saved
  !
  DEALLOCATE( tau, fion )
  !
  RETURN
  !
END SUBROUTINE metadyn
!
!------------------------------------------------------------------------
SUBROUTINE reset_vel()
  !------------------------------------------------------------------------
  !
  USE ions_positions, ONLY : tau0, taum, taus, tausm
  !
  IMPLICIT NONE
  !
  !
  taum(:,:)  = tau0(:,:)
  tausm(:,:) = taus(:,:)
  !
  RETURN
  !
END SUBROUTINE reset_vel
