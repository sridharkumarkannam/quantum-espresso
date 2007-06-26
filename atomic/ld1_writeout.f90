!
! Copyright (C) 2004 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!     
!---------------------------------------------------------------------
subroutine ld1_writeout
  !---------------------------------------------------------------------
  !
  !     This routine writes on output the quantities which defines 
  !     a multiprojector pseudopotential. It can be in the
  !     Vanderbilt form or in the norm-conserving form
  !
  use io_global, only : stdout, ionode, ionode_id
  use mp,        only : mp_bcast
  use ld1inc
  use funct, only : get_dft_name
  use atomic_paw, only : paw_io
  implicit none

  integer :: &
       ios,   &  ! I/O control
       iunps     ! the unit with the pseudopotential


  logical, external :: matches
  logical :: oldformat
  character (len=20) :: dft_name
  
  if (file_pseudopw == ' ') return

  if (nconf > 1) &
       call errore('ld1_writeout','more than one test configuration',1)

  if (.not. lpaw) then

     if (rel == 2 .and. .not. matches('.UPF',file_pseudopw) &
                  .and. .not. matches('.upf',file_pseudopw) ) then
        file_pseudopw=trim(file_pseudopw)//'.UPF'
     end if

     oldformat = .not. matches('.UPF',file_pseudopw) .and. &
                 .not. matches('.upf',file_pseudopw)

  else
     if ( .not. matches('.PAW',file_pseudopw) .and. &
          .not. matches('.paw',file_pseudopw) ) then
        file_pseudopw=trim(file_pseudopw)//'.PAW'
     end if
  end if

  iunps=28
  if (ionode) &
     open(unit=iunps, file=trim(file_pseudopw), status='unknown',  &
          form='formatted', err=50, iostat=ios)
50  call mp_bcast(ios, ionode_id)
  call errore('ld1_writeout','opening file_pseudopw',abs(ios))

  if (ionode) then
     if (lpaw) then
        !
        ! write experimental PAW setup
        !
        call paw_io(pawsetup,iunps,"OUT")
        !
     else if (oldformat) then
        !
        if (pseudotype == 1) then
          dft_name = get_dft_name()
          !
          ! write in CPMD format 
          if ( matches('.psp',file_pseudopw) ) then
             call write_cpmd &
                  (iunps,zed,xmin,dx,mesh,ndm,r,r2,  &
                  dft_name,lmax,lloc,zval,nlc,nnl,cc,alpc,alc,alps,nlcc, &
                  rhoc,vnl,phits,vpsloc,elts,llts,octs,rcut,etots,nwfts)
          else
          !
          ! write old "NC" format (semilocal)
          !
             call write_pseudo &
                  (iunps,zed,xmin,dx,mesh,ndm,r,r2,  &
                  dft_name,lmax,lloc,zval,nlc,nnl,cc,alpc,alc,alps,nlcc, &
                  rhoc,vnl,phits,vpsloc,elts,llts,octs,etots,nwfts)
          end if
        else
          !
          ! write old "RRKJ" format (nonlocal)
          !
           call write_rrkj ( iunps )
        end if
        !
     else
        !
        call write_upf(iunps)
        !
     endif
     !
     close(iunps)
  endif
  !
  return
end subroutine ld1_writeout

!---------------------------------------------------------------------
subroutine write_rrkj (iunps)
  !---------------------------------------------------------------------
  !
  use ld1inc
  use funct, only: get_iexch, get_icorr, get_igcx, get_igcc
  implicit none
  !
  integer, intent(in):: iunps ! I/O unit
  !
  integer :: nb, mb, & ! counters on beta functions
             ios,    & ! I/O control
             ir        ! counter on mesh points
  integer :: iexch, icorr, igcx, igcc
  !
  !
  write( iunps, '(a75)', err=100, iostat=ios ) title
  !
  write( iunps, '(i5)',err=100, iostat=ios ) pseudotype
  if (rel > 0) then
     write( iunps, '(2l5)',err=100, iostat=ios ) .true., nlcc
  else
     write( iunps, '(2l5)',err=100, iostat=ios ) .false., nlcc
  endif
  iexch = get_iexch()
  icorr = get_icorr()
  igcx  = get_igcx()
  igcc  = get_igcc()
  write( iunps, '(4i5)',err=100, iostat=ios ) iexch, icorr, igcx, igcc

  write( iunps, '(2e17.11,i5)') zval, etots, lmax
  write( iunps, '(4e17.11,i5)',err=100, iostat=ios ) &
       xmin,rmax,zmesh,dx,mesh

  write( iunps, '(2i5)', err=100, iostat=ios ) nwfs, nbeta
  write( iunps, '(1p4e19.11)', err=100, iostat=ios ) &
       ( rcut(nb), nb=1,nwfs )
  write( iunps, '(1p4e19.11)', err=100, iostat=ios ) &
       ( rcutus(nb), nb=1,nwfs )
  do nb=1,nwfs
     write(iunps,'(a2,2i3,f6.2)',err=100,iostat=ios) &
          els(nb), nns(nb), lls(nb), ocs(nb)
  enddo
  do nb=1,nbeta
     write ( iunps, '(i6)',err=100, iostat=ios ) ikk(nb)
     write ( iunps, '(1p4e19.11)',err=100, iostat=ios ) &
          ( betas(ir,nb), ir=1,ikk(nb))
     do mb=1,nb
        write( iunps, '(1p4e19.11)', err=100, iostat=ios ) &
             bmat(nb,mb)
        if (pseudotype == 3) then
           write(iunps,'(1p4e19.11)',err=100,iostat=ios) &
                qq(nb,mb)
           write(iunps,'(1p4e19.11)',err=100,iostat=ios) & 
                (qvan(ir,nb,mb),ir=1,mesh)
        endif
     enddo
  enddo
  !
  !   writes the local potential 
  !
  write( iunps, '(1p4e19.11)',err=100, iostat=ios ) rcloc, &
       ( vpsloc(ir), ir=1,mesh )
  !
  !   writes the atomic charge
  !
  write( iunps, '(1p4e19.11)',err=100, iostat=ios )  &
       ( rhos(ir,1), ir=1,mesh )
  !
  !   If present writes the core charge
  !
  if ( nlcc ) then 
     write( iunps, '(1p4e19.11)', err=100, iostat=ios ) &
          ( rhoc(ir), ir=1,mesh )
  endif
  !
  !    Writes the wavefunctions of the atom
  !      
  write( iunps, '(1p4e19.11)', err=100, iostat=ios ) &
       ((phis(ir,nb),ir=1,mesh),nb=1,nwfs)
100 call errore('ld1_writeout','Writing pseudopw file',abs(ios))
  !
end subroutine write_rrkj

